open! Core
open Core_unix
open Async
module Epoll = Linux_ext.Epoll

let[@cold] fd_bug_exn ~(here : [%call_pos]) fd message =
  raise_s
    [%message
      "BUG: curl_async FD tracking"
        (message : string)
        (fd : File_descr.t)
        (here : Source_code_position.t)]
;;

let max_num_open_file_descrs =
  Async_config.(Max_num_open_file_descrs.raw max_num_open_file_descrs)
;;

let epoll_max_ready_events =
  Async_config.(Epoll_max_ready_events.raw epoll_max_ready_events)
;;

module Flags = struct
  include Epoll.Flags

  let in_out = in_ + out

  let raise_poll_none () =
    raise_s
      [%message
        "BUG: libcurl docs do not specify POLL_NONE as a possible argument to \
         socketfunction, yet we received it"]
  ;;
end

type t =
  { epoll : Epoll.t
  ; epoll_fd : Fd.t
  ; on_ready : File_descr.t -> Curl.Multi.fd_status -> unit
  }

let remove_if_present t fd =
  try Epoll.remove t.epoll fd with
  | Unix.Unix_error ((EBADF | ENOENT), _, _) -> ()
;;

let handle_ready_fd t fd ready_flags =
  match Epoll.find t.epoll fd with
  | None -> ()
  | Some (_ : Flags.t) ->
    let read_ready = Flags.do_intersect ready_flags Flags.in_ in
    let write_ready = Flags.do_intersect ready_flags Flags.out in
    (match read_ready, write_ready with
     | true, false -> t.on_ready fd EV_IN
     | false, true -> t.on_ready fd EV_OUT
     | true, true -> t.on_ready fd EV_INOUT
     | false, false ->
       (* Epoll may report EPOLLERR or EPOLLHUP even when they were not requested. EV_AUTO
          tells libcurl to inspect the FD itself. This is what the libcurl epoll example
          code does. *)
       t.on_ready fd EV_AUTO)
;;

(* Process at most one ready batch per Async callback. The epoll set is level-triggered,
   and [Fd.every_ready_to] will call us again in a later Async cycle if the epoll fd
   remains readable. Avoiding an inner drain loop prevents a paused or otherwise
   still-ready curl socket from starving the scheduler. *)
let process_one_ready_batch t =
  match Epoll.wait t.epoll ~timeout:`Immediately with
  | `Timeout -> ()
  | `Ok -> Epoll.iter_ready t.epoll ~f:(handle_ready_fd t)
;;

let watch_epoll_fd t =
  let finished = Fd.every_ready_to t.epoll_fd `Read process_one_ready_batch t in
  don't_wait_for
    (match%map finished with
     | `Bad_fd -> fd_bug_exn (Epoll.Expert.file_descr t.epoll) "Bad_fd"
     | `Unsupported -> fd_bug_exn (Epoll.Expert.file_descr t.epoll) "Unsupported"
     | `Closed -> ())
;;

let create ~on_ready =
  let epoll =
    Or_error.ok_exn
      Epoll.create
      ~num_file_descrs:max_num_open_file_descrs
      ~max_ready_events:epoll_max_ready_events
  in
  let epoll_fd =
    Fd.create
      ~avoid_setting_nonblock:true
      Fifo
      (Epoll.Expert.file_descr epoll)
      (Info.of_string "libcurl-multi-epoll")
  in
  let t = { epoll; epoll_fd; on_ready } in
  watch_epoll_fd t;
  t
;;

let set_if_changed t fd flags =
  match Epoll.find t.epoll fd with
  | Some current_flags when Flags.equal current_flags flags -> ()
  | None | Some _ -> Epoll.set t.epoll fd flags
;;

let watch_fd_for_curl t unix_fd (poll : Curl.Multi.poll) =
  match poll with
  | POLL_IN -> set_if_changed t unix_fd Flags.in_
  | POLL_OUT -> set_if_changed t unix_fd Flags.out
  | POLL_INOUT -> set_if_changed t unix_fd Flags.in_out
  | POLL_REMOVE -> remove_if_present t unix_fd
  | POLL_NONE -> Flags.raise_poll_none ()
;;
