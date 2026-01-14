open! Core

module State = struct
  type 'a t =
    | Uninitialized
    | Accumulating of Bigbuffer.t
    | One_chunk_only of 'a
    (* This avoids a copy if the message is not split across multiple chunks *)
    | Finalized
end

type 'a t =
  { mutable state : 'a State.t
  ; deserializer : 'a Deserializer.t
  }

let register ?(buffer_padding = 0) curl deserializer =
  let t = { state = State.Uninitialized; deserializer } in
  Curl.set_writefunction_buf curl (fun bstr ->
    (match t.state with
     | Accumulating buffer -> Bigbuffer.add_bigstring buffer bstr
     | Uninitialized ->
       let content_length = Curl.get_contentlengthdownload curl |> Float.to_int in
       (* The most likely scenarios are that content length is known or that writefunction
          will only be called once: do minimal allocation based on this. If content length
          is unknown and writefunction is called more than once, the buffer will resize
          exponentially as needed. *)
       if Bigstring.length bstr = content_length
       then t.state <- One_chunk_only (deserializer.map_ephemeral curl bstr)
       else (
         let buffer =
           Bigbuffer.create (max content_length (Bigstring.length bstr) + buffer_padding)
         in
         t.state <- Accumulating buffer;
         Bigbuffer.add_bigstring buffer bstr)
     | One_chunk_only _ ->
       raise_s
         [%message
           [%here]
             "BUG: libcurl writefunction was called after write accumulator expected to \
              handle one chunk only"]
     | Finalized ->
       raise_s
         [%message
           [%here]
             "BUG: libcurl writefunction was called after write accumulator was finalized"]);
    Proceed ());
  t
;;

let finalize_exn t curl =
  match t.state with
  | State.Accumulating buffer ->
    (* Returning the buffer contents in this way is allowable only if we are certain no
       further buffer mutation will occur. This property is guaranteed by allowed state
       transitions where illegal state transitions will raise an exception. *)
    let bstr =
      Bigstring.unsafe_sub_shared_of_local
        ~len:(Bigbuffer.length buffer)
        (Bigbuffer.volatile_contents buffer)
    in
    t.state <- Finalized;
    t.deserializer.map curl bstr
  | One_chunk_only result -> result
  | Uninitialized ->
    (* This could be possible because docs say writefunction "_may_ be called with zero
       bytes data if the transferred file is empty", emphasis mine.

       https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html *)
    t.state <- Finalized;
    t.deserializer.map curl Bigstring.empty
  | Finalized ->
    raise_s [%message [%here] "BUG: Write accumulator was finalized more than once"]
;;
