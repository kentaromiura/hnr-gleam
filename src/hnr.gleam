import gleam/bit_array

// for glerm.print
import gleam/dict.{type Dict}

//import gleam/erlang/atom
//import gleam/erlang/process
import gleam/function
import gleam/hackney
import gleam/http/request

//import gleam/http/response
import gleam/dynamic.{field, int, list, string}
import gleam/erlang/process.{Normal}
import gleam/int

//import gleam/io.{debug}
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam_community/ansi
import gleamyshell
import glerm

// I think glexec would work best if I could find a way to pass stdin as it is...
// import glexec as exec
// using refcel to set when listening or not, need to be refactor to pass channels info 
// to cancel actions instead as now I'll always recreate the listener.
import ref

const use_alternative_screen = True

const hn_base_api = "https://hacker-news.firebaseio.com/v0/"

const hn_top = "topstories.json"

// TODO: handle self post like:
// https://news.ycombinator.com/item?id=42319315

type Story {
  Story(title: String, url: String)
}

// moved gtui code here to fix flickering issues by using glerm
type AppState {
  State(
    direction: Int,
    size: #(Int, Int),
    stories_id: List(Int),
    is_loading: Bool,
    stories: Dict(Int, String),
    selected_row: Int,
  )
}

type Message {
  GlermEvent(glerm.Event)
  TimerEvent
  LoadTop(List(Int), Dict(Int, String))
}

fn story_decoder() {
  dynamic.decode2(Story, field("title", of: string), field("url", of: string))
}

fn list_from_body(body: String) -> List(Int) {
  let ids =
    string.drop_start(from: string.drop_end(from: body, up_to: 1), up_to: 1)
  list.map(string.split(ids, ","), fn(el) { result.unwrap(int.parse(el), 0) })
}

fn fetch_items(id_list: List(Int)) {
  list.map(id_list, fn(item) {
    let assert Ok(request) =
      request.to(hn_base_api <> "item/" <> int.to_string(item) <> ".json")
    let req = hackney.send(request)
    let response = result.try(req, fn(response) { Ok(response.body) })
    #(item, result.unwrap(response, ""))
  })
}

fn print_loop(state, selector, cleanup, handle_messages) {
  // Flush entire screen (this is bad for the ui as it flickers.)
  // glerm.clear()

  glerm.move_to(0, 0)
  let _ = glerm.print(bit_array.from_string(render(state)))

  // I've tried to free the main thread every 16ms to see if input lag improves but nah
  // let timeout = 16
  // let maybe_msg = process.select(selector, timeout)
  // case maybe_msg {
  //   Ok(msg) -> {
  //     let #(new_state, running) = update(state, msg)
  //     ref.set(handle_messages, fn(_) { False })
  //     let selector = handle_exec(new_state, msg, selector, handle_messages)
  //     ref.set(handle_messages, fn(_) { True })
  //     // wait 300ms after returning, discarding all events,
  //     // this prevents q key to kill both browser and hnr
  //     let _ = process.select(selector, 300)

  //     case running {
  //       True -> print_loop(new_state, selector, cleanup, handle_messages)
  //       False -> {
  //         let _ = case use_alternative_screen {
  //           True -> glerm.leave_alternate_screen()
  //           _ -> Ok(Nil)
  //         }
  //         cleanup
  //         |> list.map(fn(x) { x() })
  //         Nil
  //       }
  //     }
  //   }
  //   _ -> {
  //     print_loop(state, selector, cleanup, handle_messages)
  //   }
  // }

  let msg = process.select_forever(selector)
  let #(new_state, running) = update(state, msg)
  let selector = handle_exec(new_state, msg, selector, handle_messages)
  // TODO: process.send(channels, Exit)
  // todo replace selector with new event listener

  case running {
    True -> print_loop(new_state, selector, cleanup, handle_messages)
    False -> {
      let _ = case use_alternative_screen {
        True -> glerm.leave_alternate_screen()
        _ -> Ok(Nil)
      }
      cleanup
      |> list.map(fn(x) { x() })
      Nil
    }
  }
}

fn do_request(request, size, subject) {
  fn() -> Nil {
    let req = hackney.send(request)
    let response = result.try(req, fn(response) { Ok(response.body) })
    let stories_id = list_from_body(result.unwrap(response, ""))
    process.send(
      subject,
      LoadTop(
        stories_id,
        dict.from_list(fetch_items(list.take(stories_id, size - 2))),
      ),
    )
    actor.continue(0)
    Nil
  }
}

fn load_tops(size: Int) -> #(process.Subject(Message), fn() -> Nil) {
  let tops_events = process.new_subject()
  let assert Ok(request) = request.to(hn_base_api <> hn_top)
  process.start(do_request(request, size, tops_events), True)

  #(tops_events, fn() {
    // no need for cleanup    
    Nil
  })
}

fn new_msg_loop(handle_messages) {
  [check_key(handle_messages), timer(handle_messages)]
}

fn enable_cursor() {
  // enable blinking cursor
  let esc_code = "\u{001b}["
  let _ = glerm.print(bit_array.from_string(esc_code <> "?25h"))
}

fn disable_cursor() {
  // very important to prevent flicker
  // disable blinking cursor
  let esc_code = "\u{001b}["
  let _ = glerm.print(bit_array.from_string(esc_code <> "?25l"))
}

pub fn main() {
  let handle_messages = ref.cell(True)
  let state = State(0, size(), [], True, dict.new(), 0)
  let #(_, rows) = state.size
  //let event_msg_setup_cleanup = [check_key(), timer(), load_tops(rows)]
  let event_msg_setup_cleanup =
    list.append(new_msg_loop(handle_messages), [load_tops(rows)])

  let selector = process.new_selector()

  let selectors =
    event_msg_setup_cleanup
    |> list.fold(selector, fn(sel, sub) {
      process.selecting(sel, sub.0, function.identity)
    })

  let cleanup =
    event_msg_setup_cleanup
    |> list.map(fn(t) { t.1 })

  let _ = case use_alternative_screen {
    True -> glerm.enter_alternate_screen()
    _ -> Ok(Nil)
  }
  // only clear screen at the start.
  glerm.clear()

  let _ = disable_cursor()
  print_loop(state, selectors, cleanup, handle_messages)
  // re-enable it
  enable_cursor()
}

fn url_from_selection(state: AppState) -> String {
  story_from_json(result.unwrap(
    dict.get(
      state.stories,
      result.unwrap(
        list.last(list.take(state.stories_id, state.selected_row + 1)),
        0,
      ),
    ),
    "",
  )).url
}

fn render(state: AppState) -> String {
  let spinner = fn(st) {
    // I added some spaces on purpose
    case st {
      0 -> "Loading ... | "
      1 -> "Loading ...  /"
      2 -> "Loading ...  -"
      3 -> "Loading ... \\ "
      _ -> panic
    }
  }

  let #(col, _lines) = state.size
  full_line(
    col,
    "Hacker News, debug terminal size: " <> size_to_string(state.size),
    ansi.bright_white,
    ansi.bg_blue,
  )
  <> render_stories(state)
  <> case state.is_loading {
    True -> spinner(state.direction)
    False ->
      full_line(
        col,
        "[" <> url_from_selection(state) <> "]",
        ansi.bright_white,
        ansi.bg_blue,
      )
  }
  // <> size_to_string(state.size)
  // <> "\n\r"
  // <> full_line(col, size_to_string(state.size), ansi.bright_white, ansi.bg_blue)
  // <> " infinite spinner \r\n"
  // <> int.to_string(list.length(state.stories_id))
  // <> " Press q to close\r\n"
}

fn story_from_json(json_str) {
  result.unwrap(
    json.decode(from: json_str, using: story_decoder()),
    Story("", ""),
  )
}

fn render_stories(state: AppState) -> String {
  let #(col, lines) = state.size
  let selected = state.selected_row
  string.join(
    list.index_map(list.take(state.stories_id, lines - 2), fn(id, idx) {
      let json =
        result.unwrap(dict.get(state.stories, id), "{title:\"\", url:\"\"}")

      //debug("JSON: " <> json)
      let story = story_from_json(json)
      //debug("story.title" <> story.title)
      case idx == selected {
        True ->
          full_line(col, "> " <> story.title, ansi.gray, ansi.bg_bright_yellow)
        False -> full_line(col, story.title, ansi.white, ansi.bg_black)
      }
    }),
    "",
  )
}

fn full_line(col, text, color, bg_color) -> String {
  bg_color(color(string.pad_end(text, to: col, with: " ")))
}

fn size_to_string(size: #(Int, Int)) -> String {
  let #(col, rows) = size
  "[" <> int.to_string(col) <> ", " <> int.to_string(rows) <> "]"
}

fn size() -> #(Int, Int) {
  //let #(col, rows) = 
  result.unwrap(glerm.size(), #(0, 0))
  //"[" <> int.to_string(col) <> ", " <> int.to_string(rows) <> "]"
}

fn handle_exec(
  state: AppState,
  msg: Message,
  selector: process.Selector(Message),
  handle_messages,
) {
  case msg {
    GlermEvent(glerm.Key(glerm.Enter, _)) -> {
      glerm.clear()
      let url = url_from_selection(state)
      //let _ = glerm.leave_alternate_screen()

      // this works but somehow executing external makes cli input slow on return
      // Since this also happens on rust I wonder if it's because internally it keeps
      // a reference to the time or something and when spawning it's not updated.
      // I think detaching/reattaching events might work...
      ref.set(handle_messages, fn(_) { False })
      let _ =
        gleamyshell.execute(
          "lynx",
          //"/Users/kentaromiura/experiments/gleam/hnr/hnr/carbonyl-0.0.3/carbonyl",
          result.unwrap(gleamyshell.cwd(), "."),
          [url],
        )

      ref.set(handle_messages, fn(_) { True })
      let _ = disable_cursor()
      //let _ = glerm.enter_alternate_screen()
      // let _ =
      //   exec.new()
      //   //|> exec.with_stdin(exec.StdinPipe)
      //   |> exec.with_stdout(
      //     exec.StdoutFun(fn(_out, _i, s) {
      //       let _ = glerm.print(bit_array.from_string(s))
      //       Nil
      //     }),
      //   )
      //   //|> exec.with_stdout(exec.StdoutCapture)
      //   |> exec.run_sync(
      //     exec.Execve([
      //       result.unwrap(
      //         exec.find_executable(
      //           "lynx",
      //           //"/Users/kentaromiura/experiments/gleam/hnr/hnr/carbonyl-0.0.3/carbonyl",
      //         ),
      //         "",
      //       ),
      //       url,
      //     ]),
      //   )

      let event_msg_setup_cleanup = new_msg_loop(handle_messages)
      event_msg_setup_cleanup
      |> list.fold(selector, fn(sel, sub) {
        process.selecting(sel, sub.0, function.identity)
      })
    }
    GlermEvent(_) -> {
      selector
    }
    _ -> {
      selector
    }
  }
}

fn update(state: AppState, msg: Message) -> #(AppState, Bool) {
  case msg {
    GlermEvent(glerm.Resize(x, y)) -> {
      glerm.clear()
      #(State(..state, size: #(x, y)), True)
    }
    GlermEvent(glerm.Key(glerm.Character("c"), option.Some(glerm.Control))) -> {
      #(state, False)
    }
    GlermEvent(glerm.Key(glerm.Up, _)) -> {
      let selected_row = case state.selected_row == 0 {
        True -> 0
        False -> state.selected_row - 1
      }
      #(State(..state, selected_row: selected_row), True)
    }
    GlermEvent(glerm.Key(glerm.Down, _)) -> {
      let selected_row = case
        state.selected_row == dict.size(state.stories) - 1
      {
        True -> dict.size(state.stories) - 1
        False -> state.selected_row + 1
      }
      #(State(..state, selected_row: selected_row), True)
    }
    GlermEvent(glerm.Key(glerm.Character("q"), _)) -> {
      #(state, False)
    }
    GlermEvent(_) -> {
      // discard mouse event or other unhandled. not working...
      #(state, True)
    }
    TimerEvent -> {
      #(State(..state, direction: { state.direction + 1 } % 4), True)
    }
    LoadTop(stories_id, stories) -> {
      #(
        State(
          ..state,
          stories_id: stories_id,
          stories: stories,
          is_loading: False,
        ),
        True,
      )
    }
    //_ -> #(state, True)
  }
}

fn check_key(handle_messages) -> #(process.Subject(Message), fn() -> Nil) {
  let glerm_events = process.new_subject()
  let assert Ok(_) = glerm.enable_raw_mode()
  //let _ = glerm.enable_mouse_capture()
  let assert Ok(_) =
    glerm.start_listener(0, fn(event, state) {
      case ref.get(handle_messages) {
        True ->
          case event {
            glerm.Mouse(glerm.ScrollDown) -> actor.continue(state)
            _ -> {
              process.send(glerm_events, GlermEvent(event))
              actor.continue(state)
            }
          }
        False -> {
          actor.Stop(Normal)
        }
      }
    })

  #(glerm_events, fn() {
    let assert Ok(_) = glerm.disable_raw_mode()
    Nil
  })
}

fn timer_function(subject, handle_messages: ref.RefCell(Bool)) {
  fn() {
    //process.sleep(300)
    process.sleep(50)
    // 16ms ~60fps
    case ref.get(handle_messages) {
      True -> {
        process.send(subject, TimerEvent)
        actor.continue(0)
        timer_function(subject, handle_messages)()
      }
      _ -> actor.Stop(Normal)
    }
  }
}

fn timer(
  handle_messages: ref.RefCell(Bool),
) -> #(process.Subject(Message), fn() -> Nil) {
  let timer_events = process.new_subject()
  process.start(timer_function(timer_events, handle_messages), True)
  #(timer_events, fn() { Nil })
}
