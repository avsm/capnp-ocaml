(******************************************************************************
 * capnp-ocaml
 *
 * Copyright (c) 2013-2014, Paul Pelzl
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *
 *  2. Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 ******************************************************************************)

(* Runtime support for Builder interfaces.  In many ways this parallels the
   Reader support, to the point of using the same function names; however,
   the underlying message must be tagged as read/write, and many functions in
   this module may allocate message space (for example, dereferencing a struct
   pointer will cause struct storage to be immediately allocated if that pointer
   was null). *)

open Core.Std

module Make (MessageWrapper : Message.S) = struct
  type rw = Message.rw
  module Reader = MessageReader.Make(MessageWrapper)
  module RC = RuntimeCommon.Make(MessageWrapper)
  include RC


  (* Allocate storage for a struct within the specified message. *)
  let alloc_struct_storage
      (message : rw Message.t)
      (data_words : int)
      (pointer_words : int)
    : rw StructStorage.t =
    let storage = Slice.alloc message
      ((data_words + pointer_words) * sizeof_uint64)
    in
    let data = {storage with Slice.len = data_words * sizeof_uint64} in
    let pointers = {
      storage with
      Slice.start = data.Slice.start + data.Slice.len;
      Slice.len   = pointer_words * sizeof_uint64;
    } in {
      StructStorage.data = data;
      StructStorage.pointers = pointers;
    }


  (* Allocate storage for a list within the specified message. *)
  let alloc_list_storage
      (message : rw Message.t)
      (storage_type : ListStorage.storage_type_t)
      (num_elements : int)
    : rw ListStorage.t =
    let storage =
      match storage_type with
      | ListStorage.Empty ->
          Slice.alloc message 0
      | ListStorage.Bit ->
          Slice.alloc message (Util.ceil_int num_elements 8)
      | ListStorage.Bytes per_element_byte_count ->
          Slice.alloc message (num_elements * per_element_byte_count)
      | ListStorage.Pointer ->
          Slice.alloc message (num_elements * sizeof_uint64)
      | ListStorage.Composite (data_words, pointer_words) ->
          (* Composite list looks a little different from the other cases:
             content is prefixed by a tag word which describes the shape of
             the content. *)
          let word_count = 1 + (num_elements * (data_words + pointer_words)) in
          let slice = Slice.alloc message (word_count * sizeof_uint64) in
          let tag_descr = {
            StructPointer.offset = num_elements;
            StructPointer.data_size = data_words;
            StructPointer.pointers_size = pointer_words;
          } in
          let tag_val = StructPointer.encode tag_descr in
          let () = Slice.set_int64 slice 0 tag_val in
          slice
    in
    let open ListStorage in {
      storage;
      storage_type;
      num_elements;
    }


  (* Given a description of a cap'n proto far pointer, get the data associated with
     the pointer.  A far pointer can either point to a normal pointer or to a
     "landing pad" with a content pointer and a tag word; [deref_normal_pointer]
     describes the method to use for dereferencing the pointer in the former case,
     and [deref_tagged_far_pointer] describes the method to use in the latter
     case. *)
  let deref_far_pointer
      (far_pointer : FarPointer.t)
      (message : rw Message.t)
      (deref_normal_pointer     : rw Slice.t -> 'a)
      (deref_tagged_far_pointer : rw Slice.t -> 'a)
    : 'a =
    let open FarPointer in
    match far_pointer.landing_pad with
    | NormalPointer ->
        let next_pointer_bytes = {
          Slice.msg        = message;
          Slice.segment_id = far_pointer.segment_id;
          Slice.start      = far_pointer.offset * sizeof_uint64;
          Slice.len        = sizeof_uint64;
        } in
        let () = bounds_check_slice_exn
          ~err:"far pointer describes invalid landing pad" next_pointer_bytes
        in
        deref_normal_pointer next_pointer_bytes
    | TaggedFarPointer ->
        let landing_pad_bytes = {
          Slice.msg        = message;
          Slice.segment_id = far_pointer.segment_id;
          Slice.start      = far_pointer.offset * sizeof_uint64;
          Slice.len        = 2 * sizeof_uint64;
        } in
        let () = bounds_check_slice_exn
          ~err:"far pointer describes invalid tagged landing pad" landing_pad_bytes
        in
        deref_tagged_far_pointer landing_pad_bytes


  (* Given a far-pointer "landing pad" which is expected to point to list storage,
     compute the corresponding list storage descriptor. *)
  let deref_list_tagged_far_pointer
      (landing_pad_bytes : rw Slice.t)
    : rw ListStorage.t =
    let far_pointer_bytes = { landing_pad_bytes with Slice.len = sizeof_uint64 } in
    let list_tag_bytes = {
      landing_pad_bytes with
      Slice.start = Slice.get_end far_pointer_bytes;
      Slice.len   = sizeof_uint64;
    } in
    match (decode_pointer far_pointer_bytes, decode_pointer list_tag_bytes) with
    | (Pointer.Far far_pointer, Pointer.List list_pointer) ->
        make_list_storage
          ~message:landing_pad_bytes.Slice.msg
          ~segment_id:far_pointer.FarPointer.segment_id
          ~segment_offset:(far_pointer.FarPointer.offset * sizeof_uint64)
          ~list_pointer
    | _ ->
        invalid_msg "invalid type tags for list-tagged far pointer"


  (* Initialize a far pointer so that it will point to the specified [content],
     which is physically located in the given [content_slice].
     [init_normal_pointer] describes how to construct a normal intra-segment
     pointer which is appropriate for the content type; [init_far_pointer_tag]
     provides a similar method for constructing the tag word found in a
     "double far" landing pad. *)
  (* FIXME: need a way to get the storage slice associated with the content... *)
  let init_far_pointer
      (pointer_bytes : rw Slice.t)
      ~(content : 'a)
      ~(content_slice : rw Slice.t)
      ~(init_normal_pointer : rw Slice.t -> 'a -> unit)
      ~(init_far_pointer_tag : rw Slice.t -> unit)
    : unit =
    let landing_pad_opt = Slice.alloc_in_segment
        content_slice.Slice.msg content_slice.Slice.segment_id sizeof_uint64
    in
    begin match landing_pad_opt with
    | Some landing_pad_bytes ->
        (* Use a "normal" far pointer. *)
        let () = init_normal_pointer landing_pad_bytes content in
        let far_pointer_desc = {
          FarPointer.landing_pad = FarPointer.NormalPointer;
          FarPointer.offset = landing_pad_bytes.Slice.start / sizeof_uint64;
          FarPointer.segment_id = landing_pad_bytes.Slice.segment_id;
        } in
        let far_pointer_val = FarPointer.encode far_pointer_desc in
        Slice.set_int64 pointer_bytes 0 far_pointer_val
    | None ->
        (* Use the "double far" convention. *)
        let landing_pad_bytes =
          let landing_pad = Slice.alloc pointer_bytes.Slice.msg (2 * sizeof_uint64) in
          let far_pointer_desc = {
            FarPointer.landing_pad = FarPointer.NormalPointer;
            FarPointer.offset = content_slice.Slice.start / 8;
            FarPointer.segment_id = content_slice.Slice.segment_id;
          } in
          let () = Slice.set_int64 landing_pad 0
            (FarPointer.encode far_pointer_desc)
          in
          let tag_slice = {
            landing_pad with
            Slice.start = landing_pad.Slice.start + sizeof_uint64;
            Slice.len   = sizeof_uint64;
          } in
          let () = init_far_pointer_tag tag_slice in
          landing_pad
        in
        let far_pointer_desc = {
          FarPointer.landing_pad = FarPointer.TaggedFarPointer;
          FarPointer.offset = landing_pad_bytes.Slice.start / sizeof_uint64;
          FarPointer.segment_id = landing_pad_bytes.Slice.segment_id;
        } in
        let far_pointer_val = FarPointer.encode far_pointer_desc in
        Slice.set_int64 pointer_bytes 0 far_pointer_val
    end


  let list_pointer_type_of_storage_type tp =
    match tp with
    | ListStorage.Empty       -> ListPointer.Void
    | ListStorage.Bit         -> ListPointer.OneBitValue
    | ListStorage.Bytes 1     -> ListPointer.OneByteValue
    | ListStorage.Bytes 2     -> ListPointer.TwoByteValue
    | ListStorage.Bytes 4     -> ListPointer.FourByteValue
    | ListStorage.Bytes 8     -> ListPointer.EightByteValue
    | ListStorage.Pointer     -> ListPointer.EightBytePointer
    | ListStorage.Composite _ -> ListPointer.Composite
    | ListStorage.Bytes _     -> assert false


  (* Given a pointer location and list storage located within the same
     message segment, modify the pointer so that it points to the list
     storage. *)
  let init_normal_list_pointer
      (pointer_bytes : rw Slice.t)
      (list_storage : rw ListStorage.t)
    : unit =
    let storage_slice = list_storage.ListStorage.storage in
    let () = assert (storage_slice.Slice.segment_id = pointer_bytes.Slice.segment_id) in
    let offset_bytes = storage_slice.Slice.start - Slice.get_end pointer_bytes in
    let () = assert (offset_bytes land 7 = 0) in
    let offset_words = offset_bytes / 8 in
    let element_type =
      list_pointer_type_of_storage_type list_storage.ListStorage.storage_type
    in
    let pointer_element_count =
      match list_storage.ListStorage.storage_type with
      | ListStorage.Composite (data_words, pointer_words) ->
          list_storage.ListStorage.num_elements * (data_words + pointer_words)
      | _ ->
          list_storage.ListStorage.num_elements
    in
    let pointer_descr = {
      ListPointer.offset = offset_words;
      ListPointer.element_type = element_type;
      ListPointer.num_elements = pointer_element_count;
    } in
    let pointer_val = ListPointer.encode pointer_descr in
    Slice.set_int64 pointer_bytes 0 pointer_val


  (* Initialize a list pointer so that it points to the specified list storage. *)
  let init_list_pointer
      (pointer_bytes : rw Slice.t)
      (list_storage : rw ListStorage.t)
    : unit =
    let storage_slice = list_storage.ListStorage.storage in
    if storage_slice.Slice.segment_id = pointer_bytes.Slice.segment_id then
      (* Use a normal intra-segment list pointer. *)
      init_normal_list_pointer pointer_bytes list_storage
    else
      let init_far_pointer_tag tag_slice =
        let pointer_element_count =
          match list_storage.ListStorage.storage_type with
          | ListStorage.Composite (data_words, pointer_words) ->
              list_storage.ListStorage.num_elements * (data_words + pointer_words)
          | _ ->
              list_storage.ListStorage.num_elements
        in
        let tag_word_desc = {
          ListPointer.offset = 0;
          ListPointer.element_type =
            list_pointer_type_of_storage_type list_storage.ListStorage.storage_type;
          ListPointer.num_elements = pointer_element_count;
        } in
        Slice.set_int64 pointer_bytes 0 (ListPointer.encode tag_word_desc)
      in
      init_far_pointer pointer_bytes
        ~content:list_storage
        ~content_slice:list_storage.ListStorage.storage
        ~init_normal_pointer:init_normal_list_pointer
        ~init_far_pointer_tag


  (* Given a pointer which is expected to be a list pointer, compute the corresponding
     list storage descriptor.  If the pointer is null, storage for a default list is
     immediately allocated using [alloc_default_list]. *)
  let rec deref_list_pointer
      (pointer_bytes : rw Slice.t)
      (alloc_default_list : rw Message.t -> rw ListStorage.t)
    : rw ListStorage.t =
    match decode_pointer pointer_bytes with
    | Pointer.Null ->
        let list_storage = alloc_default_list pointer_bytes.Slice.msg in
        let () = init_list_pointer pointer_bytes list_storage in
        list_storage
    | Pointer.List list_pointer ->
        make_list_storage
          ~message:pointer_bytes.Slice.msg
          ~segment_id:pointer_bytes.Slice.segment_id
          ~segment_offset:((Slice.get_end pointer_bytes) +
                             (list_pointer.ListPointer.offset * sizeof_uint64))
          ~list_pointer
    | Pointer.Far far_pointer ->
        let deref_normal_pointer pointer_bytes' =
          deref_list_pointer pointer_bytes' alloc_default_list
        in
        deref_far_pointer far_pointer pointer_bytes.Slice.msg
          deref_normal_pointer deref_list_tagged_far_pointer
    | Pointer.Struct _ ->
        invalid_msg "decoded struct pointer where list pointer was expected"


  (* Given a far-pointer "landing pad" which is expected to point to struct storage,
     compute the corresponding struct storage descriptor. *)
  let deref_struct_tagged_far_pointer
      (landing_pad_bytes : rw Slice.t)
    : rw StructStorage.t =
    let far_pointer_bytes = {
      landing_pad_bytes with
      Slice.len = sizeof_uint64
    } in
    let struct_tag_bytes = {
      landing_pad_bytes with
      Slice.start = Slice.get_end far_pointer_bytes;
      Slice.len   = sizeof_uint64;
    } in
    match (decode_pointer far_pointer_bytes, decode_pointer struct_tag_bytes) with
    | (Pointer.Far far_pointer, Pointer.Struct struct_pointer) ->
        let data = {
          Slice.msg        = landing_pad_bytes.Slice.msg;
          Slice.segment_id = far_pointer.FarPointer.segment_id;
          Slice.start      = far_pointer.FarPointer.offset * sizeof_uint64;
          Slice.len        = struct_pointer.StructPointer.data_size * sizeof_uint64;
        } in
        let pointers = {
          data with
          Slice.start = Slice.get_end data;
          Slice.len   = struct_pointer.StructPointer.pointers_size * sizeof_uint64;
        } in
        let () = bounds_check_slice_exn
          ~err:"struct-tagged far pointer describes invalid data region" data
        in
        let () = bounds_check_slice_exn
          ~err:"struct-tagged far pointer describes invalid pointers region" pointers
        in
        { StructStorage.data; StructStorage.pointers; }
    | _ ->
        invalid_msg "invalid type tags for struct-tagged far pointer"


  (* Given a pointer location and struct storage located within the same
     message segment, modify the pointer so that it points to the struct
     storage. *)
  let init_normal_struct_pointer
      (pointer_bytes : rw Slice.t)
      (struct_storage : rw StructStorage.t)
    : unit =
    let () = assert (struct_storage.StructStorage.data.Slice.segment_id =
      pointer_bytes.Slice.segment_id)
    in
    let pointer_descr = {
      StructPointer.offset = struct_storage.StructStorage.data.Slice.start -
          Slice.get_end pointer_bytes;
      StructPointer.data_size = struct_storage.StructStorage.data.Slice.len / 8;
      StructPointer.pointers_size = struct_storage.StructStorage.pointers.Slice.len / 8;
    } in
    let pointer_val = StructPointer.encode pointer_descr in
    Slice.set_int64 pointer_bytes 0 pointer_val


  (* Initialize a struct pointer so that it points to the specified struct storage. *)
  let init_struct_pointer
      (pointer_bytes : rw Slice.t)
      (struct_storage : rw StructStorage.t)
    : unit =
    if struct_storage.StructStorage.data.Slice.segment_id =
        pointer_bytes.Slice.segment_id then
      (* Use a normal intra-segment struct pointer. *)
      init_normal_struct_pointer pointer_bytes struct_storage
    else
      let init_far_pointer_tag tag_slice =
        let tag_word_desc = {
          StructPointer.offset = 0;
          StructPointer.data_size = struct_storage.StructStorage.data.Slice.len / 8;
          StructPointer.pointers_size = struct_storage.StructStorage.pointers.Slice.len / 8;
        } in
        Slice.set_int64 pointer_bytes 0 (StructPointer.encode tag_word_desc)
      in
      let content_slice = {
        struct_storage.StructStorage.data with
        Slice.len = struct_storage.StructStorage.data.Slice.len +
            struct_storage.StructStorage.pointers.Slice.len
      } in
      init_far_pointer pointer_bytes
        ~content:struct_storage
        ~content_slice
        ~init_normal_pointer:init_normal_struct_pointer
        ~init_far_pointer_tag


  (* Copy a pointer from the source slice to the destination slice.  If the
     source and destination are in different segments, this may result in
     allocating additional message space to instantiate a far pointer. *)
  let copy_pointer
      ~(src : rw Slice.t)
      ~(dest : rw Slice.t)
    : unit =
    match decode_pointer src with
    | Pointer.Null ->
        Slice.set_int64 dest 0 Int64.zero
    | Pointer.List src_descr ->
        begin match Reader.deref_list_pointer src with
        | Some list_storage ->
            init_list_pointer dest list_storage
        | None ->
            (* shouldn't happen for non-null pointer *)
            assert false
        end
    | Pointer.Struct src_descr ->
        begin match Reader.deref_struct_pointer src with
        | Some struct_storage ->
            init_struct_pointer dest struct_storage
        | None ->
            (* shouldn't happen for non-null pointer *)
            assert false
        end
    | Pointer.Far _ ->
        let pointer_val = Slice.get_int64 src 0 in
        Slice.set_int64 dest 0 pointer_val


  (* Upgrade a struct so that its data and pointer regions are at least as large
     as the protocol currently specifies.  If the [orig] struct satisfies the
     requirements of the [data_words] and [pointer_words], this is a no-op.
     Otherwise a new struct is allocated, the data is copied over, and the [orig]
     is zeroed out. *)
  let upgrade_struct
      ~(data_words : int)
      ~(pointer_words : int)
      (orig : rw StructStorage.t)
    : rw StructStorage.t =
    let open StructStorage in
    if orig.data.Slice.len < data_words * sizeof_uint64 ||
       orig.pointers.Slice.len < pointer_words * sizeof_uint64 then
      let new_storage =
        alloc_struct_storage orig.data.Slice.msg data_words pointer_words
      in
      (* This could be more efficient with a Slice.blit implementation... *)
      let () =
        let data_copy_words = min data_words (orig.data.Slice.len / sizeof_uint64) in
        for i = 0 to data_copy_words - 1 do
          let old_data = Slice.get_int64 orig.data (i * sizeof_uint64) in
          Slice.set_int64 new_storage.data (i * sizeof_uint64) old_data
        done;
        let pointer_copy_words =
          min pointer_words (orig.pointers.Slice.len / sizeof_uint64)
        in
        for i = 0 to pointer_copy_words - 1 do
          let src = {
            orig.pointers with
            Slice.start = orig.pointers.Slice.start + (i * sizeof_uint64);
            Slice.len = sizeof_uint64;
          } in
          let dest = {
            new_storage.pointers with
            Slice.start = new_storage.pointers.Slice.start + (i * sizeof_uint64);
            Slice.len = sizeof_uint64;
          } in
          copy_pointer ~src ~dest
        done
      in
      new_storage
    else
      orig


  (* Given a pointer which is expected to be a struct pointer, compute the corresponding
     struct storage descriptor.  If the pointer is null, storage for a default struct
     is immediately allocated using [alloc_default_struct].  [data_words] and
     [pointer_words] indicate the expected structure layout; if the struct has a
     smaller layout (i.e. from an older protocol version), then a new struct is
     allocated and the data is copied over. *)
  let rec deref_struct_pointer
      (pointer_bytes : rw Slice.t)
      (alloc_default_struct : rw Message.t -> rw StructStorage.t)
      ~(data_words : int)
      ~(pointer_words : int)
    : rw StructStorage.t =
    match decode_pointer pointer_bytes with
    | Pointer.Null ->
        let struct_storage = alloc_default_struct pointer_bytes.Slice.msg in
        let () = init_struct_pointer pointer_bytes struct_storage in
        struct_storage
    | Pointer.Struct struct_pointer ->
        let open StructPointer in
        let data = {
          pointer_bytes with
          Slice.start = (Slice.get_end pointer_bytes) +
                          (struct_pointer.offset * sizeof_uint64);
          Slice.len   = struct_pointer.data_size * sizeof_uint64;
        } in
        let pointers = {
          data with
          Slice.start = Slice.get_end data;
          Slice.len   = struct_pointer.pointers_size * sizeof_uint64;
        } in
        let () = bounds_check_slice_exn
          ~err:"struct pointer describes invalid data region" data
        in
        let () = bounds_check_slice_exn
          ~err:"struct pointer describes invalid pointers region" data
        in
        let orig_storage = { StructStorage.data; StructStorage.pointers; } in
        upgrade_struct ~data_words ~pointer_words orig_storage
    | Pointer.Far far_pointer ->
        let deref_normal_pointer pointer_bytes' = deref_struct_pointer
            pointer_bytes' alloc_default_struct ~data_words ~pointer_words
        in
        deref_far_pointer far_pointer pointer_bytes.Slice.msg
          deref_normal_pointer deref_struct_tagged_far_pointer
    | Pointer.List _ ->
        invalid_msg "decoded list pointer where struct pointer was expected"


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto Data payload. *)
  let get_struct_field_blob
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
      ~(default : string)
    : string =
    let pointer_bytes = {
      struct_storage.StructStorage.pointers with
      Slice.start = pointer_word * sizeof_uint64;
      Slice.len   = sizeof_uint64;
    } in
    (* Data fields are always accessed by value, not by reference, since
       we always do an immediate decode to [string].  Therefore we can
       use the Reader logic to handle this case. *)
    match Reader.deref_list_pointer pointer_bytes with
    | Some list_storage ->
        string_of_uint8_list ~null_terminated:false list_storage
    | None ->
        default


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto Text payload. *)
  let get_struct_field_text
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
      ~(default : string)
    : string =
    let pointer_bytes = {
      struct_storage.StructStorage.pointers with
      Slice.start = pointer_word * sizeof_uint64;
      Slice.len   = sizeof_uint64;
    } in
    (* Text fields are always accessed by value, not by reference, since
       we always do an immediate decode to [string].  Therefore we can
       use the Reader logic to handle this case. *)
    match Reader.deref_list_pointer pointer_bytes with
    | Some list_storage ->
        string_of_uint8_list ~null_terminated:true list_storage
    | None ->
        default


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<Bool>. *)
  let get_struct_field_bit_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : ('a, 'b) Runtime.Array.t =
    let pointer_bytes = {
      struct_storage.StructStorage.pointers with
      Slice.start = pointer_word * sizeof_uint64;
      Slice.len   = sizeof_uint64;
    } in
    let alloc_default_list message =
      alloc_list_storage message ListStorage.Bit 0
    in
    let list_storage = deref_list_pointer pointer_bytes alloc_default_list in
    Runtime.Array.make
      ~length:(fun x -> x.ListStorage.num_elements)
      ~get:BitList.get
      list_storage


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto list encoded as packed bytes (e.g. List<UInt32>).
     The size of each list element in bytes is provided as [element_size],
     and the [convert] function is used to decode packed bytes as list
     elements. *)
  let get_struct_field_bytes_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
      ~(element_size : int)
      ~(convert : rw Slice.t -> 'a)
    : ('a, 'b) Runtime.Array.t =
    let pointer_bytes = {
      struct_storage.StructStorage.pointers with
      Slice.start = pointer_word * sizeof_uint64;
      Slice.len   = sizeof_uint64;
    } in
    let alloc_default_list message =
      alloc_list_storage message (ListStorage.Bytes element_size) 0
    in
    let list_storage = deref_list_pointer pointer_bytes alloc_default_list in
    Runtime.Array.make
      ~length:(fun x -> x.ListStorage.num_elements)
      ~get:(fun x i -> convert (BytesList.get x i))
      list_storage


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<Int8>. *)
  let get_struct_field_int8_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (int, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:1 ~convert:(fun slice -> Slice.get_int8 slice 0)


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<Int16>. *)
  let get_struct_field_int16_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (int, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:2 ~convert:(fun slice -> Slice.get_int16 slice 0)


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<Int32>. *)
  let get_struct_field_int32_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (int32, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:4 ~convert:(fun slice -> Slice.get_int32 slice 0)


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<Int64>. *)
  let get_struct_field_int64_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (int64, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:8 ~convert:(fun slice -> Slice.get_int64 slice 0)


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<UInt8>. *)
  let get_struct_field_uint8_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (int, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:1 ~convert:(fun slice -> Slice.get_uint8 slice 0)


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<UInt16>. *)
  let get_struct_field_uint16_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (int, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:2 ~convert:(fun slice -> Slice.get_uint16 slice 0)


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<UInt32>. *)
  let get_struct_field_uint32_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (Uint32.t, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:4 ~convert:(fun slice -> Slice.get_uint32 slice 0)


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<UInt64>. *)
  let get_struct_field_uint64_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (Uint64.t, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:8 ~convert:(fun slice -> Slice.get_uint64 slice 0)


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<Float32>. *)
  let get_struct_field_float32_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (float, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:4
      ~convert:(fun slice -> Int32.float_of_bits (Slice.get_int32 slice 0))


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<Float64>. *)
  let get_struct_field_float64_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (float, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:8
      ~convert:(fun slice -> Int64.float_of_bits (Slice.get_int64 slice 0))


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<Text>. *)
  let get_struct_field_text_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (string, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:8
      ~convert:(fun slice ->
        let pointer_bytes = {
          struct_storage.StructStorage.pointers with
          Slice.start = pointer_word * sizeof_uint64;
          Slice.len   = sizeof_uint64;
        } in
        (* Text fields are always accessed by value, not by reference, since
           we always do an immediate decode to [string].  Therefore we can
           use the Reader logic to handle this case. *)
        match Reader.deref_list_pointer pointer_bytes with
        | Some list_storage ->
            string_of_uint8_list ~null_terminated:true list_storage
        | None ->
            "")


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<Data>. *)
  let get_struct_field_blob_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (string, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:8
      ~convert:(fun slice ->
        let pointer_bytes = {
          struct_storage.StructStorage.pointers with
          Slice.start = pointer_word * sizeof_uint64;
          Slice.len   = sizeof_uint64;
        } in
        (* Data fields are always accessed by value, not by reference, since
           we always do an immediate decode to [string].  Therefore we can
           use the Reader logic to handle this case. *)
        match Reader.deref_list_pointer pointer_bytes with
        | Some list_storage ->
            string_of_uint8_list ~null_terminated:false list_storage
        | None ->
            "")


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<S> for some struct S.  The [data_words] and
     [pointer_words] describe the struct layout. *)
  let get_struct_field_struct_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
      ~(data_words : int)
      ~(pointer_words : int)
    : ('a, 'b) Runtime.Array.t =
    let pointer_bytes = {
      struct_storage.StructStorage.pointers with
      Slice.start = pointer_word * sizeof_uint64;
      Slice.len   = sizeof_uint64;
    } in
    let alloc_default_list message =
      alloc_list_storage message (ListStorage.Composite (data_words, pointer_words)) 0
    in
    let list_storage = deref_list_pointer pointer_bytes alloc_default_list in
    Runtime.Array.make
      ~length:(fun x -> x.ListStorage.num_elements)
      ~get:(fun x i -> Some (StructList.get x i))
      list_storage


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<L> for some list L. *)
  let get_struct_field_list_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
    : (rw ListStorage.t, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:8
      ~convert:(fun slice ->
        let alloc_default_list message =
          alloc_list_storage message ListStorage.Pointer 0
        in
        deref_list_pointer slice alloc_default_list)


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto List<E> for some enum E. *)
  let get_struct_field_enum_list
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
      (convert : int -> 'a)
    : ('a, 'b) Runtime.Array.t =
    get_struct_field_bytes_list struct_storage pointer_word
      ~element_size:2
      ~convert:(fun slice -> convert (Slice.get_uint16 slice 0))


  (* Given storage for a struct, get the data for the specified
     struct-embedded pointer under the assumption that it points to a
     cap'n proto struct.  The [data_words] and [pointer_words] indicate
     the structure layout. *)
  let get_struct_field_struct
      (struct_storage : rw StructStorage.t)
      (pointer_word : int)
      ~(data_words : int)
      ~(pointer_words : int)
    : rw StructStorage.t =
    let pointer_bytes = {
      struct_storage.StructStorage.pointers with
      Slice.start = pointer_word * sizeof_uint64;
      Slice.len   = sizeof_uint64;
    } in
    let alloc_default_struct message =
      alloc_struct_storage message data_words pointer_words
    in
    deref_struct_pointer pointer_bytes alloc_default_struct
      ~data_words ~pointer_words


  (* Given storage for a struct, decode the boolean field stored
     at the given byte and bit offset within the struct's data region. *)
  let get_struct_field_bit
      (struct_storage : rw StructStorage.t)
      ~(default_bit : bool)
      (byte_ofs : int) (bit_ofs : int)
    : bool =
    let byte_val = Slice.get_uint8 struct_storage.StructStorage.data byte_ofs in
    let bit_val = (byte_val land (1 lsl bit_ofs)) <> 0 in
    if default_bit then not bit_val else bit_val


  (* Given storage for a struct, decode the UInt8 field stored
     at the given byte offset within the struct's data region. *)
  let get_struct_field_uint8
      (struct_storage : rw StructStorage.t)
      ~(default : int) (byte_ofs : int)
    : int =
    let numeric = Slice.get_uint8 struct_storage.StructStorage.data byte_ofs in
    numeric lxor default


  (* Given storage for a struct, decode the UInt16 field stored
     at the given byte offset within the struct's data region. *)
  let get_struct_field_uint16
      (struct_storage : rw StructStorage.t)
      ~(default : int) (byte_ofs : int)
    : int =
    let numeric = Slice.get_uint16 struct_storage.StructStorage.data byte_ofs in
    numeric lxor default


  (* Given storage for a struct, decode the UInt32 field stored
     at the given byte offset within the struct's data region. *)
  let get_struct_field_uint32
      (struct_storage : rw StructStorage.t)
      ~(default : Uint32.t) (byte_ofs : int)
    : Uint32.t =
    let numeric = Slice.get_uint32 struct_storage.StructStorage.data byte_ofs in
    Uint32.logxor numeric default


  (* Given storage for a struct, decode the UInt64 field stored
     at the given byte offset within the struct's data region. *)
  let get_struct_field_uint64
      (struct_storage : rw StructStorage.t)
      ~(default : Uint64.t) (byte_ofs : int)
    : Uint64.t =
    let numeric = Slice.get_uint64 struct_storage.StructStorage.data byte_ofs in
    Uint64.logxor numeric default


  (* Given storage for a struct, decode the Int8 field stored
     at the given byte offset within the struct's data region. *)
  let get_struct_field_int8
      (struct_storage : rw StructStorage.t)
      ~(default : int) (byte_ofs : int)
    : int =
    let numeric = Slice.get_int8 struct_storage.StructStorage.data byte_ofs in
    numeric lxor default


  (* Given storage for a struct, decode the Int16 field stored
     at the given byte offset within the struct's data region. *)
  let get_struct_field_int16
      (struct_storage : rw StructStorage.t)
      ~(default : int) (byte_ofs : int)
    : int =
    let numeric = Slice.get_int16 struct_storage.StructStorage.data byte_ofs in
    numeric lxor default


  (* Given storage for a struct, decode the Int32 field stored
     at the given byte offset within the struct's data region. *)
  let get_struct_field_int32
      (struct_storage : rw StructStorage.t)
      ~(default : int32) (byte_ofs : int)
    : Int32.t =
    let numeric = Slice.get_int32 struct_storage.StructStorage.data byte_ofs in
    Int32.bit_xor numeric default


  (* Given storage for a struct, decode the Int64 field stored
     at the given byte offset within the struct's data region. *)
  let get_struct_field_int64
      (struct_storage : rw StructStorage.t)
      ~(default : int64) (byte_ofs : int)
    : Int64.t =
    let numeric = Slice.get_int64 struct_storage.StructStorage.data byte_ofs in
    Int64.bit_xor numeric default


  (* Locate the storage region corresponding to the root struct of a message.
     The [data_words] and [pointer_words] specify the expected struct layout. *)
  let get_root_struct
      (m : rw Message.t)
      ~(data_words : int)
      ~(pointer_words : int)
    : rw StructStorage.t =
    let first_segment = Message.get_segment m 0 in
    if Segment.length first_segment < sizeof_uint64 then
      invalid_msg "message is too small to contain root struct pointer"
    else
      let pointer_bytes = {
        Slice.msg        = m;
        Slice.segment_id = 0;
        Slice.start      = 0;
        Slice.len        = sizeof_uint64
      } in
      let alloc_default_struct message =
        alloc_struct_storage message data_words pointer_words
      in
      deref_struct_pointer pointer_bytes alloc_default_struct
        ~data_words ~pointer_words


  (* Allocate a new message of at least the given [message_size], creating a
     root struct with the specified struct layout.
     Returns: newly-allocated root struct storage *)
  let alloc_root_struct
      ~(data_words : int)
      ~(pointer_words : int)
      ~(message_size : int)
    : rw StructStorage.t =
    let message_size =
      max message_size ((data_words + pointer_words + 1) * sizeof_uint64)
    in
    let message = Message.create message_size in
    (* Has the important side effect of reserving space in the message for
       the root struct pointer... *)
    let _ = Slice.alloc message sizeof_uint64 in
    get_root_struct message ~data_words ~pointer_words

end

