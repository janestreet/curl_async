(** Functions for deserializing a payload to a return value *)

open! Core

type 'a t =
  { map : Curl.t -> Bigstring.t -> 'a
  ; map_ephemeral : Curl.t -> local_ Bigstring.t -> 'a
  }

val bigstring_body : Bigstring.t t
val bigstring_response : Bigstring.t Http_response.t t
