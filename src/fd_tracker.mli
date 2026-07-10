(** libcurl's multi API expects an application library to watch file descriptors using
    epoll or similar and to invoke a callback when an FD becomes ready. This module
    contains a dedicated epoll instance that implements this behavior.

    Async provides FD watching directly, but via a wrapper around epoll that imposes
    well-intentioned but problematic rules, making it unusable for this purpose:

    1. Async restricts changes to the state of FD watching to Async cycle boundaries. This
       means that changes to how Async should watch an FD do not take place immediately
       like they would when using epoll directly. Most notably, libcurl will close an FD
       immediately after a callback informing the external watcher to stop watching, but
       Async will not immediately stop watching the FD when told to do so. This can result
       in a top-level exception.

    2. Changes to the state of Async FD watching must be externally sequenced by the
       application: most state changes may not be requested unless any previously
       requested change is complete. For example, the application may not request that
       Async stop watching a FD and then again request watching the same FD without
       waiting for completion of the first request. Not sequencing in this way will result
       in a top-level exception from the Async scheduler. This is particularly relevant
       because libcurl will reuse connections across requests for performance, resulting
       in possibly rapid changes to FD watching state that Async cannot directly handle.

    libcurl gives us https://curl.se/libcurl/c/CURLOPT_CLOSESOCKETFUNCTION.html which can
    be used to partly work around this issue. However, not all FDs that libcurl needs to
    have watched are sockets, so this does not actually solve the problem with immediately
    closed FDs.

    It is possible to build libcurl with '--disable-socketpair' which can be used in
    conjunction with CLOSESOCKETFUNCTION to reliably work around the closed FD issue. The
    workaround code is complex (available in history) and there are other uses of libcurl
    that do not work with this compilation flag, so this is also not a usable solution.

    Use of a dedicated epoll that is in turn watched by Async is the best solution to this
    problem that we've found. *)

open! Core

type t

(** Creates an FD tracker. There should be one [t] per libcurl multi handle.

    [~on_ready] is invoked with the ready file descriptor and translated libcurl event
    status whenever epoll reports readiness for a watched file descriptor. *)
val create : on_ready:(Core_unix.File_descr.t -> Curl.Multi.fd_status -> unit) -> t

(** Records the requested watch state for a file descriptor in the dedicated epoll set.
    When the file descriptor later becomes ready, [create]'s [~on_ready] callback is
    invoked. *)
val watch_fd_for_curl : t -> Core_unix.File_descr.t -> Curl.Multi.poll -> unit
