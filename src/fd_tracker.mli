(** libcurl's multi API expects an application library to watch file descriptors using
    epoll or similar and invoke a callback when an FD becomes ready. This type of
    interaction is simple with epoll but unfortunately is difficult in Async, which
    imposes a state machine in front of FD watching. This is done with the intention of
    increased safety but in practice requires complex workarounds which are provided by
    this module.

    Details:

    There are empirically some unwritten rules of watching FDs with Async that this module
    must follow:

    1. Async restricts changes to the state of FD watching to Async cycle boundaries. This
       means that changes to how Async should watch an FD do not take place immediately
       like they would when using epoll directly.

    2. Changes to the state of Async FD watching must be externally sequenced by the
       application: most state changes may not be requested unless any previously
       requested change is complete. For example, the application may not request that
       Async stop watching a FD and then again request watching the same FD without
       waiting for completion of the first request. Not sequencing in this way will result
       in a top-level exception from the Async scheduler. This is particularly relevant
       because libcurl will reuse connections across requests for performance, resulting
       in possibly rapid changes to FD watching state that Async cannot directly handle.

    3. The owner of an FD may not close the FD if Async is watching it. Doing so will
       result in a top-level exception from the Async scheduler. The application must
       either remove Async's watching and wait for the resulting state transition before
       closing the FD or must allow Async to close the FD itself.

    libcurl gives us a hook that lets Async deal with closing sockets:
    https://curl.se/libcurl/c/CURLOPT_CLOSESOCKETFUNCTION.html. However, this is just for
    sockets and not all FDs. libcurl also uses socketpairs internally by default, will
    instruct an external event system to watch socketpair FDs, and will NOT call a
    registered closesocketfunction to close socketpair FDs. This behavior will cause async
    to raise. A workaround for this is to build libcurl with the compile-time flag
    '--disable-socketpair'. This flag is not the default, so async is unlikely to be
    compatible with a libcurl provided by an OS package manager. It is possible that
    '--disable-socketpair' has a small negative impact on latency and efficiency.

    It is possible that this could all be much simpler with something like an Expert
    module for Async's FD handling code that would let the developer bypass the internal
    state machine and just work with epoll. *)

open! Core

type t

(** Creates an FD tracker to accompany the given libcurl multi handle. There should be one
    [t] per multi handle.

    @param watch_dwell_time
      Wait this long after a request to stop watching a file descriptor before actually
      performing the request, potentially not unwatching the FD at all if another request
      to watch is received within this span. This lets libcurl reuse open connetions
      without needing to wait for Async. Defaults to 100ms. *)
val create : ?watch_dwell_time:Time_ns.Span.t -> Curl.Multi.mt -> t

(** Sets watching of a file descriptor into a requested state and invokes
    [curl_multi_socket_action] on resulting events. Emulates the use of [epoll_ctl] on top
    of Async. *)
val emulate_epoll_ctl_for_curl : t -> Core_unix.File_descr.t -> Curl.Multi.poll -> unit

(** Closes an FD in a way that Async FD watching can tolerate without raising. *)
val close : t -> Core_unix.File_descr.t -> unit
