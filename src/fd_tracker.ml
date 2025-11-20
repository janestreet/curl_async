open! Core
open Core_unix
open Async

let[@cold] fd_bug_exn ~(here : [%call_pos]) fd message =
  raise_s
    [%message
      "BUG: curl_async FD tracking"
        (message : string)
        (fd : Fd.t)
        (here : Source_code_position.t)]
;;

module State_machine = struct
  module Watch = struct
    type t =
      { interrupt : unit Ivar.t
      ; finished : unit Deferred.t
      }

    let create fd unix_fd multi_handle read_or_write curl_event =
      let interrupt = Ivar.create () in
      let finished =
        match%map
          Fd.interruptible_every_ready_to
            fd
            read_or_write
            ~interrupt:(Ivar.read interrupt)
            (fun () ->
              let (_running_handles : int) =
                Curl.Multi.action
                  (* curl_multi_socket_action *) multi_handle
                  unix_fd
                  curl_event
              in
              ())
            ()
        with
        | `Bad_fd -> fd_bug_exn fd "Bad_fd"
        | `Unsupported -> fd_bug_exn fd "Unsupported"
        | `Closed | `Interrupted -> ()
      in
      { interrupt; finished }
    ;;
  end

  module Unwatch = struct
    type t =
      { event : Clock_ns.Event.t_unit
      ; watch : Watch.t
      }
  end

  module State = struct
    type t =
      | Uninitialized
      | Watch of Watch.t Deferred.t
      | Unwatch_pending of Unwatch.t Deferred.t
  end

  type t = { mutable state : State.t }

  let create () = { state = Uninitialized }

  let watch t fd unix_fd multi_handle read_or_write curl_event =
    match t.state with
    | Watch _ -> ()
    | Uninitialized ->
      let watch =
        Watch.create fd unix_fd multi_handle read_or_write curl_event |> return
      in
      t.state <- Watch watch
    | Unwatch_pending unwatch ->
      let watch =
        let%bind { watch; event } = unwatch in
        match Clock_ns.Event.abort event () with
        | Previously_happened () ->
          let%map () = watch.finished in
          Watch.create fd unix_fd multi_handle read_or_write curl_event
        | Previously_aborted () -> fd_bug_exn fd "Previously_aborted"
        | Ok ->
          (match%bind Clock_ns.Event.fired event with
           | Aborted () -> return watch
           | Happened () ->
             let%map () = watch.finished in
             Watch.create fd unix_fd multi_handle read_or_write curl_event)
      in
      t.state <- Watch watch
  ;;

  let unwatch t watch_dwell_time =
    match t.state with
    | Uninitialized | Unwatch_pending _ -> ()
    | Watch watch ->
      let unwatch =
        let%map watch in
        let event =
          (* Wait a short time before actually interrupting the watch so that libcurl can
             possibly reuse a connection without waiting for Async state transitions. *)
          Clock_ns.Event.run_after
            watch_dwell_time
            (fun { Watch.interrupt; _ } -> Ivar.fill_exn interrupt ())
            watch
        in
        { Unwatch.watch; event }
      in
      t.state <- Unwatch_pending unwatch
  ;;
end

module Context = struct
  type t =
    { fd : Fd.t
    ; read_state : State_machine.t
    ; write_state : State_machine.t
    }

  let create unix_fd =
    let fd = Fd.create (Socket `Active) unix_fd (Base.Info.of_string "libcurl-multi") in
    { fd; read_state = State_machine.create (); write_state = State_machine.create () }
  ;;
end

type t =
  { contexts : Context.t Option_array.t
  ; multi_handle : Curl.Multi.mt
  ; watch_dwell_time : Time_ns.Span.t
  }

let create ?(watch_dwell_time = Time_ns.Span.of_int_ms 100) multi_handle =
  { multi_handle
  ; contexts =
      Option_array.create
        ~len:Async_config.(Max_num_open_file_descrs.raw max_num_open_file_descrs)
  ; watch_dwell_time
  }
;;

let[@inline] find_or_create_context contexts unix_fd =
  if Option_array.is_some contexts (unix_fd |> File_descr.to_int)
  then Option_array.unsafe_get_some_assuming_some contexts (unix_fd |> File_descr.to_int)
  else (
    let context = Context.create unix_fd in
    Option_array.unsafe_set_some contexts (unix_fd |> File_descr.to_int) context;
    context)
;;

let emulate_epoll_ctl_for_curl
  { contexts; multi_handle; watch_dwell_time }
  unix_fd
  (poll : Curl.Multi.poll)
  =
  match poll with
  | POLL_IN ->
    let { Context.fd; read_state; write_state } =
      find_or_create_context contexts unix_fd
    in
    State_machine.watch read_state fd unix_fd multi_handle `Read EV_IN;
    State_machine.unwatch write_state watch_dwell_time
  | POLL_OUT ->
    let { Context.fd; read_state; write_state } =
      find_or_create_context contexts unix_fd
    in
    State_machine.unwatch read_state watch_dwell_time;
    State_machine.watch write_state fd unix_fd multi_handle `Write EV_OUT
  | POLL_INOUT ->
    let { Context.fd; read_state; write_state } =
      find_or_create_context contexts unix_fd
    in
    State_machine.watch read_state fd unix_fd multi_handle `Read EV_IN;
    State_machine.watch write_state fd unix_fd multi_handle `Write EV_OUT
  | POLL_REMOVE ->
    (* This case does not look like the others because we don't want to create a [Fd.t] if
       one does not already exist. *)
    if Option_array.is_some contexts (unix_fd |> File_descr.to_int)
    then (
      let { Context.fd = _; read_state; write_state } =
        Option_array.unsafe_get_some_assuming_some contexts (unix_fd |> File_descr.to_int)
      in
      State_machine.unwatch read_state watch_dwell_time;
      State_machine.unwatch write_state watch_dwell_time)
  | POLL_NONE ->
    raise_s
      [%message
        [%here]
          "BUG: libcurl does not specify POLL_NONE as a possible argument to \
           socketfunction"]
;;

let close { contexts; multi_handle = _; watch_dwell_time = _ } unix_fd =
  if Option_array.is_some contexts (unix_fd |> File_descr.to_int)
  then (
    let { Context.fd; read_state = _; write_state = _ } =
      Option_array.unsafe_get_some_assuming_some contexts (unix_fd |> File_descr.to_int)
    in
    Option_array.unsafe_set_none contexts (unix_fd |> File_descr.to_int);
    don't_wait_for (Fd.close fd))
  else
    (* I don't believe this is possible from documentation. If this happens then
       investigation is needed. *)
    raise_s
      [%message [%here] "BUG: Close called on non-tracked FD" (unix_fd : File_descr.t)]
;;
