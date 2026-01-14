open Core

type 'a t =
  { http_code : int
  ; body : 'a
  ; headers : (string, string) List.Assoc.t
  }
[@@deriving sexp_of]
