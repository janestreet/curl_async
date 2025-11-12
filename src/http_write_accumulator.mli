(** Accumulate data written to a [Curl.t] as part of an HTTP request.

    It is typical for libcurl to provide data to the application in chunks, typically up
    to 16kB, even if HTTP chunked transfer encoding is not used. This module accumulates
    these chunked writes into a single buffer in an efficient way.

    This module prioritizes performance over safety. The caller must understand the
    contstraints documented for this module in conjunction with how libcurl will provide
    data to the application. *)

open! Core

type 'a t

(** Create a write accumulator and register it onto the [Curl.t] to accumulate writes.

    Only one accumulator may be registered for a [Curl.t] at any given time. The most
    recently registered accumulator is the only one that will receive written data. This
    is relevant when reusing a [Curl.t] for repeated similar requests for performance. *)
val register : ?buffer_padding:int -> Curl.t -> 'a Deserializer.t -> 'a t

(** Provide all accumulated data (if any).

    For a typical HTTP request [finalize_exn] should be called once after the
    [Curl.curlCode] of the request is determined. There may be specialied use cases, such
    as with websockets, for which this usage is not valid.

    The [t] is no longer usable after a call to [finalize_exn]:

    If [finalize_exn] is called more than once on a [t] an excpetion will be raised.

    If additional data is written to the [Curl.t] provided to [register] after
    [finalize_exn] is called and exception will be raised, except in the case that a
    [Curl.t] is intentionally reused by first calling [register] again. *)
val finalize_exn : 'a t -> Curl.t -> 'a
