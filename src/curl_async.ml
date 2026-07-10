open Core
open Async

type shared
type independent

type 'perm t =
  { multi_handle : Curl.Multi.mt
  ; results : (Curl.t, Curl.curlCode Ivar.t) Hashtbl.Poly.t
  (* libcurl gives us a way to associate arbitrary application data with a curl handle,
     but this is not currently exposed in a typeful way in the available bindings. We use
     an external hash table to accomplish the same thing. While it would be more elegant
     to not need this table, the performance penalty is negligible so we don't care. *)
  (* The hash and compare functions defined as part of custom blocks (in C) are exposed in
     OCaml as polymorphic, so using [Hashtbl.Poly] here is actually the right thing to do.
     If not using Poly ever matters, these operations could instead be plumbed through as
     external functions. *)
  }

(* Global init should occur once before using libcurl *)
let global_init = lazy (Curl.global_init CURLINIT_GLOBALALL)

let[@inline] completion_found ~key:curl ~data:waiter results code =
  Ivar.fill_exn waiter code;
  Hashtbl.remove results curl
;;

let rec check_completions t =
  (* calls [curl_multi_info_read] and [curl_multi_remove_handle] *)
  match Curl.Multi.remove_finished t.multi_handle with
  | None -> ()
  | Some (curl, code) ->
    Hashtbl.findi_and_call2
      t.results
      curl
      ~a:t.results
      ~b:code
      ~if_found:completion_found
      ~if_not_found:(fun _ _ _ -> ());
    (check_completions [@tailcall]) t
;;

let on_timeout t =
  Curl.Multi.action_timeout t.multi_handle;
  check_completions t
;;

(* A dummy value to be used for timer callback state initialiation *)
let aborted_event =
  lazy
    (let event = Clock_ns.Event.run_at Time_ns.epoch ignore () in
     Clock_ns.Event.abort_exn event ();
     event)
;;

(* Implements use of the libcurl-multi API prescribed by
   https://curl.se/libcurl/c/libcurl-multi.html

   The most relevant example code is
   https://github.com/curl/curl/blob/master/docs/examples/ephiperfifo.c
*)
let create () =
  let multi_handle = (* curl_multi_init *) Curl.Multi.create () in
  let t = { multi_handle; results = Hashtbl.Poly.create () } in
  let on_ready unix_fd curl_event =
    let (_running_handles : int) = Curl.Multi.action t.multi_handle unix_fd curl_event in
    check_completions t
  in
  let fd_tracker = Fd_tracker.create ~on_ready in
  Curl.Multi.set_socket_function
    (* https://curl.se/libcurl/c/CURLMOPT_SOCKETFUNCTION.html *)
    multi_handle
    (fun unix_fd poll -> Fd_tracker.watch_fd_for_curl fd_tracker unix_fd poll);
  Curl.Multi.set_timer_function
    (* https://curl.se/libcurl/c/CURLMOPT_TIMERFUNCTION.html *)
    multi_handle
    (let event = ref (force aborted_event) in
     fun timeout_ms ->
       Clock_ns.Event.abort_if_possible !event ();
       if timeout_ms = 0
       then
         (* By far the most common request from libcurl is for an immediate timeout. By
            enqueueing into the scheduler directly we avoid allocating an event. libcurl
            will not request another timeout before the enqueued one runs. *)
         Scheduler.(enqueue_job (current_execution_context ())) on_timeout t
       else if timeout_ms = -1
       then
         (* -1 means cancel. [abort_if_possible] was already called so nothing left to do *)
         ()
       else (
         let timeout = Time_ns.Span.of_int_ms timeout_ms in
         event := Clock_ns.Event.run_after timeout on_timeout t));
  t
;;

let t =
  let t = lazy (create ()) in
  fun () -> force t
;;

let curl_error curl_code error =
  Error.create_s
    [%sexp { curl_code = (Curl.strerror curl_code : string); error : string }]
;;

module Curl_code_and_error = struct
  type t =
    { curl_code : Curl.curlCode
    ; error : string
    }
end

let perform_curl { multi_handle; results } curl =
  Monitor.try_with_or_error ~here:[%here] (fun () ->
    let error_buffer = ref "" in
    Curl.set_errorbuffer curl error_buffer;
    let result = Ivar.create () in
    Hashtbl.add_exn results ~key:curl ~data:result;
    Curl.Multi.add multi_handle curl;
    let%map.Deferred curl_code = Ivar.read result in
    { Curl_code_and_error.curl_code; error = !error_buffer })
;;

let perform t curl =
  match%map perform_curl t curl with
  | Ok { curl_code = CURLE_OK; error = _ } -> Ok ()
  | Ok { curl_code; error } -> Error (curl_error curl_code error)
  | Error _ as error -> error
;;

module Http = struct
  module Deserializer = Deserializer
  module Response = Http_response

  module Response_style = struct
    type _ t =
      | Body : Bigstring.t t
      | Response : Bigstring.t Response.t t
      | Map : 'a Deserializer.t -> 'a t
  end

  let accumulate t ?buffer_padding curl deserializer =
    let accumulator = Http_write_accumulator.register ?buffer_padding curl deserializer in
    let%map.Deferred.Or_error () = perform t curl in
    Http_write_accumulator.finalize_exn accumulator curl
  ;;

  let[@inline] http_code_is_success http_code = http_code >= 200 && http_code < 300
  let headers curl = Curl.get_headers curl [ CURLH_HEADER ] ~request:(-1)

  module Streaming_state = struct
    type t =
      { curl : Curl.t
      ; multi_handle : Curl.Multi.mt
      ; writer : Bigstring.t Pipe.Writer.t
      ; headers_ready : unit Ivar.t
      ; mutable first_chunk_received : bool
      ; mutable paused : bool
      ; mutable transfer_done : bool
      }

    let unpause t =
      t.paused <- false;
      Curl.pause t.curl [];
      Curl.Multi.action_timeout t.multi_handle
    ;;

    let pause t =
      t.paused <- true;
      don't_wait_for
        (let%map.Deferred () = Pipe.pushback t.writer in
         if t.paused && not t.transfer_done then unpause t)
    ;;

    let create ~curl ~multi_handle ~writer ~headers_ready =
      let t =
        { curl
        ; multi_handle
        ; writer
        ; headers_ready
        ; first_chunk_received = false
        ; paused = false
        ; transfer_done = false
        }
      in
      (* If the consumer closes the reader, actively wake up curl so the next write
         callback can return [Curl.Abort]. Without this, a paused transfer would sit
         forever waiting for the pipe to drain. (A transfer that is neither paused nor
         actively transferring data still has to rely on libcurl's own timeouts to notice;
         cancelling such a transfer cleanly would require exposing [Curl.Multi.remove]
         through [Curl_async], which is out of scope here.) *)
      don't_wait_for
        (let%map.Deferred () = Pipe.closed writer in
         if t.paused && not t.transfer_done then unpause t);
      t
    ;;

    let mark_first_chunk_received t =
      if not t.first_chunk_received
      then (
        t.first_chunk_received <- true;
        Ivar.fill_if_empty t.headers_ready ())
    ;;

    let mark_transfer_done t =
      t.transfer_done <- true;
      Ivar.fill_if_empty t.headers_ready ()
    ;;

    let can_write t = Deferred.is_determined (Pipe.pushback t.writer)
  end

  let default_streaming_buffer_size_budget = 16 (* 256kB with curl's 16kB chunks *)

  let create_streaming_writefunction (streaming_state : Streaming_state.t) =
    stage (fun bstr ->
      Streaming_state.mark_first_chunk_received streaming_state;
      match Pipe.is_closed streaming_state.writer with
      | true -> Curl.Abort
      | false ->
        (match Streaming_state.can_write streaming_state with
         | false ->
           Streaming_state.pause streaming_state;
           Curl.Pause
         | true ->
           let chunk = Bigstring.copy bstr in
           Pipe.write_without_pushback streaming_state.writer chunk;
           Curl.Proceed ()))
  ;;

  let with_streaming_response t ?streaming_buffer_size_budget curl ~f =
    let headers_ready = Ivar.create () in
    let transfer_result = Ivar.create () in
    let size_budget =
      Option.value
        ~default:default_streaming_buffer_size_budget
        streaming_buffer_size_budget
    in
    let body =
      Pipe_with_writer_error.create_reader ~size_budget (fun writer ->
        let streaming_state =
          Streaming_state.create ~curl ~multi_handle:t.multi_handle ~writer ~headers_ready
        in
        Curl.set_writefunction_buf
          curl
          (create_streaming_writefunction streaming_state |> unstage);
        let%map.Deferred result = perform t curl in
        Streaming_state.mark_transfer_done streaming_state;
        Ivar.fill_exn transfer_result result;
        result)
    in
    (* Wait for headers to be available (first chunk received or transfer complete) *)
    let%bind.Deferred () = Ivar.read headers_ready in
    match Deferred.peek (Ivar.read transfer_result) with
    | Some (Error error) -> Deferred.Or_error.fail error
    | Some (Ok ()) | None ->
      let http_code = Curl.get_httpcode curl in
      let headers = headers curl in
      let response = { Response.http_code; headers; body } in
      Monitor.protect
        (fun () -> f response)
        ~finally:(fun () ->
          (* Make sure the body pipe is closed so the writefunction returns [Curl.Abort]
             if there are still chunks pending, and wait for the underlying transfer to
             complete before handing control back to the caller. This is what makes it
             safe for the caller to [Curl.cleanup] the handle once
             [with_streaming_response] returns. *)
          Pipe_with_writer_error.close body;
          let%map.Deferred (_ : unit Or_error.t) = Ivar.read transfer_result in
          ())
  ;;

  let perform (type response) t ?buffer_padding curl (style : response Response_style.t) =
    match style with
    | Body ->
      (accumulate t ?buffer_padding curl Deserializer.bigstring_body
       : response Deferred.Or_error.t)
    | Response -> accumulate t ?buffer_padding curl Deserializer.bigstring_response
    | Map deserializer -> accumulate t ?buffer_padding curl deserializer
  ;;
end

module Expert = struct
  module Curl_code_and_error = Curl_code_and_error

  let perform = perform
  let perform_curl = perform_curl
  let multi_handle { multi_handle; _ } = multi_handle
end
