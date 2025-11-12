open! Core

type 'a t =
  { map : Curl.t -> Bigstring.t -> 'a
  ; map_ephemeral : Curl.t -> local_ Bigstring.t -> 'a
  }

let bigstring_body =
  { map = (fun _curl bstr -> bstr)
  ; map_ephemeral = (fun _curl bstr -> Bigstring.copy bstr)
  }
;;

let headers curl = Curl.get_headers curl [ CURLH_HEADER ] ~request:(-1)

let bigstring_response =
  { map =
      (fun curl bstr ->
        let http_code = Curl.get_httpcode curl in
        let headers = headers curl in
        { Http_response.http_code; body = bstr; headers })
  ; map_ephemeral =
      (fun curl bstr ->
        let http_code = Curl.get_httpcode curl in
        let headers = headers curl in
        { Http_response.http_code; body = Bigstring.copy bstr; headers })
  }
;;
