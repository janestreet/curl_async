(** Curl_async performs network transfers for a [Curl.t] within Async using libcurl's
    multi API. This is useful for developers wanting to work directly with libcurl.

    If you just want to make an HTTP request, instead have a look at [Curl_jane].

    See https://curl.se/libcurl/c/libcurl-multi.html *)

open! Core
open Async

type shared
type independent
type 'perm t

(** Create or retrieve a globally shared instance of a [t] *)
val t : unit -> shared t

(** Created a unique t that is not the shared instance. This is useful if you need to
    change options that affect the behavior of the Curl multi handle. *)
val create : unit -> independent t

(** Force this value to globally initialize libcurl. This should be done before any other
    API call.

    See https://curl.se/libcurl/c/curl_global_init.html *)
val global_init : unit lazy_t

module Http : sig
  module Response = Http_response
  module Deserializer = Deserializer

  module Response_style : sig
    type _ t =
      | Body : Bigstring.t t
      | Response : Bigstring.t Response.t t
      | Map : 'a Deserializer.t -> 'a t
  end

  (** Perform an HTTP request and return the response *)
  val perform
    :  _ t
    -> ?buffer_padding:int
    -> Curl.t
    -> 'a Response_style.t
    -> 'a Deferred.Or_error.t

  val headers : Curl.t -> (string, string) List.Assoc.t
  val http_code_is_success : int -> bool
end

(** The intended audience for the Expert submodule is developers who understand libcurl in
    detail and (probably) are implementing a protocol or something else with specific
    requirements.

    See https://curl.se/libcurl/c/ libcurl documentation. *)
module Expert : sig
  (** Performs network transfers for the provided [Curl.t].

      This function is useful as a building block for a protocol implementation or if
      you're doing something special with libcurl. This function won't be useful for most
      people and notably does not set up write handling. *)
  val perform : _ t -> Curl.t -> unit Deferred.Or_error.t

  module Curl_code_and_error : sig
    type t =
      { curl_code : Curl.curlCode
      ; error : string
      }
  end

  (** Like [perform], but returns a type that gives the appliation access to the
      enumerated [Curl.curlCode]. The application may wish to match on this code in
      unusual use cases.

      In the event of an error, the returned error string may be populated by libcurl with
      more detailed error information and will otherwise be empty. *)
  val perform_curl : _ t -> Curl.t -> Curl_code_and_error.t Deferred.Or_error.t

  (** Access the curl multi handle belonging to this [t]. This is useful to set options
      that affect all transfers processed by the multi handle.

      See https://curl.se/libcurl/c/multi_setopt_options.html *)
  val multi_handle : independent t -> Curl.Multi.mt
end
