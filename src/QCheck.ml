
(*
QCheck: Random testing for OCaml
Copyright (C) 2016  Vincent Hugot, Simon Cruanes

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Library General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Library General Public License for more details.

You should have received a copy of the GNU Lesser General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*)

(** {1 Quickcheck inspired property-based testing} *)

open Printf

module RS = Random.State

let rec foldn ~f ~init:acc i =
  if i = 0 then acc else foldn ~f ~init:(f acc i) (i-1)

let _is_some = function Some _ -> true | None -> false

let _opt_map_or ~d ~f = function
  | None -> d
  | Some x -> f x

let _opt_or a b = match a with
  | None -> b
  | Some x -> x

let _opt_map ~f = function
  | None -> None
  | Some x -> Some (f x)

let _opt_map_2 ~f a b = match a, b with
  | Some x, Some y -> Some (f x y)
  | _ -> None

let _opt_map_3 ~f a b c = match a, b, c with
  | Some x, Some y, Some z -> Some (f x y z)
  | _ -> None

let _opt_map_4 ~f a b c d = match a, b, c, d with
  | Some x, Some y, Some z, Some w -> Some (f x y z w)
  | _ -> None

let _opt_sum a b = match a, b with
  | Some _, _ -> a
  | None, _ -> b

let sum_int = List.fold_left (+) 0

exception FailedPrecondition
(* raised if precondition is false *)

let assume b = if not b then raise FailedPrecondition

let assume_fail () = raise FailedPrecondition

let (==>) b1 b2 = if b1 then b2 else raise FailedPrecondition

module Gen = struct
  type 'a t = RS.t -> 'a
  type 'a sized = int -> Random.State.t -> 'a

  let return x _st = x

  let (>>=) gen f st =
    f (gen st) st

  let (<*>) f x st = f st (x st)
  let map f x st = f (x st)
  let map2 f x y st = f (x st) (y st)
  let map3 f x y z st = f (x st) (y st) (z st)
  let map_keep_input f gen st = let x = gen st in x, f x
  let (>|=) x f = map f x

  let oneof l st = List.nth l (Random.State.int st (List.length l)) st
  let oneofl xs st = List.nth xs (Random.State.int st (List.length xs))
  let oneofa xs st = Array.get xs (Random.State.int st (Array.length xs))

  let frequencyl l st =
    let sums = sum_int (List.map fst l) in
    let i = Random.State.int st sums in
    let rec aux acc = function
      | ((x,g)::xs) -> if i < acc+x then g else aux (acc+x) xs
      | _ -> failwith "frequency"
    in
    aux 0 l

  let frequencya a = frequencyl (Array.to_list a)

  let frequency l st = frequencyl l st st

  (* natural number generator *)
  let nat st =
    let p = RS.float st 1. in
    if p < 0.5 then RS.int st 10
    else if p < 0.75 then RS.int st 100
    else if p < 0.95 then RS.int st 1_000
    else RS.int st 10_000

  let small_nat = nat

  let unit _st = ()

  let bool st = RS.bool st

  let float st =
    exp (RS.float st 15. *. (if RS.float st 1. < 0.5 then 1. else -1.))
    *. (if RS.float st 1. < 0.5 then 1. else -1.)

  let pfloat st = abs_float (float st)
  let nfloat st = -.(pfloat st)

  let neg_int st = -(nat st)

  let opt f st =
    let p = RS.float st 1. in
    if p < 0.15 then None
    else Some (f st)

  (* Uniform random int generator *)
  let pint =
    if Sys.word_size = 32 then
      fun st -> RS.bits st
    else (* word size = 64 *)
      fun st ->
        RS.bits st                        (* Bottom 30 bits *)
        lor (RS.bits st lsl 30)           (* Middle 30 bits *)
        lor ((RS.bits st land 3) lsl 60)  (* Top 2 bits *)  (* top bit = 0 *)

  let int st = if RS.bool st then - (pint st) - 1 else pint st
  let int_bound n =
    if n < 0 then invalid_arg "Gen.int_bound";
    fun st ->
      let r = pint st in
      r mod (n+1)
  let int_range a b =
    if b < a then invalid_arg "Gen.int_range";
    fun st -> a + (int_bound (b-a) st)
  let (--) = int_range

  (* NOTE: we keep this alias to not break code that uses [small_int]
     for sizes of strings, arrays, etc. *)
  let small_int = small_nat

  let small_signed_int st =
    if bool st
    then small_nat st
    else - (small_nat st)

  let random_binary_string st length =
    (* 0b011101... *)
    let s = Bytes.create (length + 2) in
    Bytes.set s 0 '0';
    Bytes.set s 1 'b';
    for i = 0 to length - 1 do
      Bytes.set s (i+2) (if RS.bool st then '0' else '1')
    done;
    Bytes.unsafe_to_string s

  let ui32 st = Int32.of_string (random_binary_string st 32)
  let ui64 st = Int64.of_string (random_binary_string st 64)

  let list_size size gen st =
    foldn ~f:(fun acc _ -> (gen st)::acc) ~init:[] (size st)
  let list gen st = list_size nat gen st
  let list_repeat n g = list_size (return n) g

  let array_size size gen st =
    Array.init (size st) (fun _ -> gen st)
  let array gen st = array_size nat gen st
  let array_repeat n g = array_size (return n) g

  let shuffle_a a st =
    for i = Array.length a-1 downto 1 do
      let j = Random.State.int st (i+1) in
      let tmp = a.(i) in
      a.(i) <- a.(j);
      a.(j) <- tmp;
    done

  let shuffle_l l st =
    let a = Array.of_list l in
    shuffle_a a st;
    Array.to_list a

  let pair g1 g2 st = (g1 st, g2 st)

  let triple g1 g2 g3 st = (g1 st, g2 st, g3 st)

  let quad g1 g2 g3 g4 st = (g1 st, g2 st, g3 st, g4 st)

  let char st = char_of_int (RS.int st 256)

  let printable_chars =
    let l = 126-32+1 in
    let s = Bytes.create l in
    for i = 0 to l-2 do
      Bytes.set s i (char_of_int (32+i))
    done;
    Bytes.set s (l-1) '\n';
    Bytes.unsafe_to_string s

  let printable st = printable_chars.[RS.int st (String.length printable_chars)]
  let numeral st = char_of_int (48 + RS.int st 10)

  let string_size ?(gen = char) size st =
    let s = Bytes.create (size st) in
    for i = 0 to Bytes.length s - 1 do
      Bytes.set s i (gen st)
    done;
    Bytes.unsafe_to_string s
  let string ?gen st = string_size ?gen small_nat st
  let small_string ?gen st = string_size ?gen (0--10) st
  let small_list gen = list_size (0--10) gen

  let join g st = (g st) st

  (* corner cases *)

  let graft_corners gen corners () =
    let cors = ref corners in fun st ->
      match !cors with [] -> gen st
      | e::l -> cors := l; e

  let nng_corners () = graft_corners nat [0;1;2;max_int] ()

  (* sized, fix *)

  let sized_size s f st = f (s st) st
  let sized f = sized_size nat f

  let fix f =
    let rec f' n st = f f' n st in
    f'

  let generate ?(rand=Random.State.make_self_init()) ~n g =
    list_repeat n g rand

  let generate1 ?(rand=Random.State.make_self_init()) g = g rand
end

module Print = struct
  type 'a t = 'a -> string

  let unit _ = "()"
  let int = string_of_int
  let bool = string_of_bool
  let float = string_of_float
  let string s = s
  let char c = String.make 1 c

  let option f = function
    | None -> "None"
    | Some x -> "Some (" ^ f x ^ ")"

  let pair a b (x,y) = Printf.sprintf "(%s, %s)" (a x) (b y)
  let triple a b c (x,y,z) = Printf.sprintf "(%s, %s, %s)" (a x) (b y) (c z)
  let quad a b c d (x,y,z,w) =
    Printf.sprintf "(%s, %s, %s, %s)" (a x) (b y) (c z) (d w)

  let list pp l =
    let b = Buffer.create 25 in
    Buffer.add_char b '[';
    List.iteri (fun i x ->
      if i > 0 then Buffer.add_string b "; ";
      Buffer.add_string b (pp x))
      l;
    Buffer.add_char b ']';
    Buffer.contents b

  let array pp a =
    let b = Buffer.create 25 in
    Buffer.add_string b "[|";
    Array.iteri (fun i x ->
      if i > 0 then Buffer.add_string b "; ";
      Buffer.add_string b (pp x))
      a;
    Buffer.add_string b "|]";
    Buffer.contents b

  let comap f p x = p (f x)
end

module Iter = struct
  type 'a t = ('a -> unit) -> unit
  let empty _ = ()
  let return x yield = yield x
  let (<*>) a b yield = a (fun f -> b (fun x ->  yield (f x)))
  let (>>=) a f yield = a (fun x -> f x yield)
  let map f a yield = a (fun x -> yield (f x))
  let map2 f a b yield = a (fun x -> b (fun y -> yield (f x y)))
  let (>|=) a f = map f a
  let append a b yield = a yield; b yield
  let (<+>) = append
  let of_list l yield = List.iter yield l
  let of_array a yield = Array.iter yield a
  let pair a b yield = a (fun x -> b(fun y -> yield (x,y)))
  let triple a b c yield = a (fun x -> b (fun y -> c (fun z -> yield (x,y,z))))
  let quad a b c d yield =
    a (fun x -> b (fun y -> c (fun z -> d (fun w -> yield (x,y,z,w)))))

  exception IterExit
  let find p iter =
    let r = ref None in
    (try iter (fun x -> if p x then (r := Some x; raise IterExit))
     with IterExit -> ()
    );
    !r
end

module Shrink = struct
  type 'a t = 'a -> 'a Iter.t

  let nil _ = Iter.empty
  let unit = nil

  (* get closer to 0 *)
  let int x yield =
    if x < -2 || x>2 then yield (x/2); (* faster this way *)
    if x>0 then yield (x-1);
    if x<0 then yield (x+1)

  let char c yield =
    if Char.code c > 0 then yield (Char.chr (Char.code c-1))

  let option s x = match x with
    | None -> Iter.empty
    | Some x -> Iter.(return None <+> map (fun y->Some y) (s x))

  let string s yield =
    for i =0 to String.length s-1 do
      let s' = Bytes.init (String.length s-1)
        (fun j -> if j<i then s.[j] else s.[j+1])
      in
      yield (Bytes.unsafe_to_string s')
    done

  let array ?shrink a yield =
    for i=0 to Array.length a-1 do
      let a' = Array.init (Array.length a-1)
        (fun j -> if j< i then a.(j) else a.(j+1))
      in
      yield a'
    done;
    match shrink with
    | None -> ()
    | Some f ->
        (* try to shrink each element of the array *)
        for i = 0 to Array.length a - 1 do
          f a.(i) (fun x ->
            let b = Array.copy a in
            b.(i) <- x;
            yield b
          )
        done

  let list ?shrink l yield =
    let rec aux l r = match r with
      | [] -> ()
      | x :: r' ->
          yield (List.rev_append l r');
          aux (x::l) r'
    in
    aux [] l;
    match shrink with
    | None -> ()
    | Some f ->
        let rec aux l r = match r with
          | [] -> ()
          | x :: r' ->
              f x (fun x' -> yield (List.rev_append l (x' :: r')));
              aux (x :: l) r'
        in
        aux [] l

  let pair a b (x,y) yield =
    a x (fun x' -> yield (x',y));
    b y (fun y' -> yield (x,y'))

  let triple a b c (x,y,z) yield =
    a x (fun x' -> yield (x',y,z));
    b y (fun y' -> yield (x,y',z));
    c z (fun z' -> yield (x,y,z'))

  let quad a b c d (x,y,z,w) yield =
    a x (fun x' -> yield (x',y,z,w));
    b y (fun y' -> yield (x,y',z,w));
    c z (fun z' -> yield (x,y,z',w));
    d w (fun w' -> yield (x,y,z,w'))
end

(** {2 Observe Values} *)

module Observable = struct
  (** An observable is a (random) predicate on ['a] *)
  type -'a t = {
    print: 'a Print.t;
    eq: ('a -> 'a -> bool);
    hash: ('a -> int);
  }

  let make ?(eq=(=)) ?(hash=Hashtbl.hash) print =
    {print; eq; hash; }

  module H = struct
    let combine a b = Hashtbl.seeded_hash a b
    let combine_f f s x = Hashtbl.seeded_hash s (f x)
    let int i = i land max_int
    let bool b = if b then 1 else 2
    let char x = Char.code x
    let string (x:string) = Hashtbl.hash x
    let opt f = function
      | None -> 42
      | Some x -> combine 43 (f x)
    let list f l = List.fold_left (combine_f f) 0x42 l
    let array f l = Array.fold_left (combine_f f) 0x42 l
    let pair f g (x,y) = combine (f x) (g y)
  end

  module Eq = struct
    type 'a t = 'a -> 'a -> bool

    let int : int t = (=)
    let string : string t = (=)
    let bool : bool t = (=)
    let float : float t = (=)
    let unit () () = true
    let char : char t = (=)

    let rec list f l1 l2 = match l1, l2 with
      | [], [] -> true
      | [], _ | _, [] -> false
      | x1::l1', x2::l2' -> f x1 x2 && list f l1' l2'

    let array eq a b =
      let rec aux i =
        if i = Array.length a then true
        else eq a.(i) b.(i) && aux (i+1)
      in
      Array.length a = Array.length b
      &&
      aux 0

    let option f o1 o2 = match o1, o2 with
      | None, None -> true
      | Some _, None
      | None, Some _ -> false
      | Some x, Some y -> f x y

    let pair f g (x1,y1)(x2,y2) = f x1 x2 && g y1 y2
  end

  let unit : unit t = make ~hash:(fun _ -> 1) ~eq:Eq.unit Print.unit
  let bool : bool t = make ~hash:H.bool ~eq:Eq.bool Print.bool
  let int : int t = make ~hash:H.int ~eq:Eq.int Print.int
  let float : float t = make ~eq:Eq.float Print.float
  let string = make ~hash:H.string ~eq:Eq.string Print.string
  let char = make ~hash:H.char ~eq:Eq.char Print.char

  let option p =
    make ~hash:(H.opt p.hash) ~eq:(Eq.option p.eq)
      (Print.option p.print)

  let array p =
    make ~hash:(H.array p.hash) ~eq:(Eq.array p.eq) (Print.array p.print)
  let list p =
    make ~hash:(H.list p.hash) ~eq:(Eq.list p.eq) (Print.list p.print)

  let map f p =
    make ~hash:(fun x -> p.hash (f x)) ~eq:(fun x y -> p.eq (f x)(f y))
      (fun x -> p.print (f x))

  let pair a b =
    make ~hash:(H.pair a.hash b.hash) ~eq:(Eq.pair a.eq b.eq) (Print.pair a.print b.print)
  let triple a b c =
    map (fun (x,y,z) -> x,(y,z)) (pair a (pair b c))
  let quad a b c d =
    map (fun (x,y,z,u) -> x,(y,z,u)) (pair a (triple b c d))
end

type 'a stat = string * ('a -> int)
(** A statistic on a distribution of values of type ['a] *)

type 'a arbitrary = {
  gen: 'a Gen.t;
  print: ('a -> string) option; (** print values *)
  small: ('a -> int) option;  (** size of example *)
  shrink: ('a -> 'a Iter.t) option;  (** shrink to smaller examples *)
  collect: ('a -> string) option;  (** map value to tag, and group by tag *)
  stats: 'a stat list; (** statistics to collect and print *)
}

let make ?print ?small ?shrink ?collect ?(stats=[]) gen = {
  gen;
  print;
  small;
  shrink;
  collect;
  stats;
}

let set_small f o = {o with small=Some f}
let set_print f o = {o with print=Some f}
let set_shrink f o = {o with shrink=Some f}
let set_collect f o = {o with collect=Some f}
let set_stats s o = {o with stats=s}
let add_stat s o = {o with stats=s :: o.stats}

let small1 _ = 1

let make_scalar ?print ?collect gen =
  make ~shrink:Shrink.nil ~small:small1 ?print ?collect gen
let make_int ?collect gen =
  make ~shrink:Shrink.int ~small:small1 ~print:Print.int ?collect gen

let adapt_ o gen =
  make ?print:o.print ?small:o.small ?shrink:o.shrink ?collect:o.collect gen

let choose l = match l with
  | [] -> raise (Invalid_argument "quickcheck.choose")
  | l ->
      let a = Array.of_list l in
      adapt_ a.(0)
        (fun st ->
          let arb = a.(RS.int st (Array.length a)) in
          arb.gen st)

let unit : unit arbitrary =
  make ~small:small1 ~shrink:Shrink.nil ~print:(fun _ -> "()") Gen.unit

let bool = make_scalar ~print:string_of_bool Gen.bool
let float = make_scalar ~print:string_of_float Gen.float
let pos_float = make_scalar ~print:string_of_float Gen.pfloat
let neg_float = make_scalar ~print:string_of_float Gen.nfloat

let int = make_int Gen.int
let int_bound n = make_int (Gen.int_bound n)
let int_range a b = make_int (Gen.int_range a b)
let (--) = int_range
let pos_int = make_int Gen.pint
let small_int = make_int Gen.small_int
let small_nat = make_int Gen.small_nat
let small_signed_int = make_int Gen.small_signed_int
let small_int_corners () = make_int (Gen.nng_corners ())
let neg_int = make_int Gen.neg_int

let int32 = make_scalar ~print:(fun i -> Int32.to_string i ^ "l") Gen.ui32
let int64 = make_scalar ~print:(fun i -> Int64.to_string i ^ "L") Gen.ui64

let char = make_scalar ~print:(sprintf "%C") Gen.char
let printable_char = make_scalar ~print:(sprintf "%C") Gen.printable
let numeral_char = make_scalar ~print:(sprintf "%C") Gen.numeral

let string_gen_of_size size gen =
  make ~shrink:Shrink.string ~small:String.length
    ~print:(sprintf "%S") (Gen.string_size ~gen size)
let string_gen gen =
  make ~shrink:Shrink.string ~small:String.length
    ~print:(sprintf "%S") (Gen.string ~gen)

let string = string_gen Gen.char
let string_of_size size = string_gen_of_size size Gen.char
let small_string = string_gen_of_size Gen.(0--10) Gen.char

let printable_string = string_gen Gen.printable
let printable_string_of_size size = string_gen_of_size size Gen.printable
let small_printable_string = string_gen_of_size Gen.(0--10) Gen.printable

let numeral_string = string_gen Gen.numeral
let numeral_string_of_size size = string_gen_of_size size Gen.numeral

let list_sum_ f l = List.fold_left (fun acc x-> f x+acc) 0 l

let mk_list a gen =
  (* small sums sub-sizes if present, otherwise just length *)
  let small = _opt_map_or a.small ~f:list_sum_ ~d:List.length in
  let print = _opt_map a.print ~f:Print.list in
  make ~small ~shrink:(Shrink.list ?shrink:a.shrink) ?print gen

let list a = mk_list a (Gen.list a.gen)
let list_of_size size a = mk_list a (Gen.list_size size a.gen)
let small_list a = mk_list a (Gen.small_list a.gen)

let array_sum_ f a = Array.fold_left (fun acc x -> f x+acc) 0 a

let array a =
  let small = _opt_map_or ~d:Array.length ~f:array_sum_ a.small in
  make
    ~small
    ~shrink:(Shrink.array ?shrink:a.shrink)
    ?print:(_opt_map ~f:Print.array a.print)
    (Gen.array a.gen)

let array_of_size size a =
  let small = _opt_map_or ~d:Array.length ~f:array_sum_ a.small in
  make
    ~small
    ~shrink:(Shrink.array ?shrink:a.shrink)
    ?print:(_opt_map ~f:Print.array a.print)
    (Gen.array_size size a.gen)

let pair a b =
  make
    ?small:(_opt_map_2 ~f:(fun f g (x,y) -> f x+g y) a.small b.small)
    ?print:(_opt_map_2 ~f:Print.pair a.print b.print)
    ~shrink:(Shrink.pair (_opt_or a.shrink Shrink.nil) (_opt_or b.shrink Shrink.nil))
    (Gen.pair a.gen b.gen)

let triple a b c =
  make
    ?small:(_opt_map_3 ~f:(fun f g h (x,y,z) -> f x+g y+h z) a.small b.small c.small)
    ?print:(_opt_map_3 ~f:Print.triple a.print b.print c.print)
    ~shrink:(Shrink.triple (_opt_or a.shrink Shrink.nil)
      (_opt_or b.shrink Shrink.nil) (_opt_or c.shrink Shrink.nil))
    (Gen.triple a.gen b.gen c.gen)

let quad a b c d =
  make
    ?small:(_opt_map_4 ~f:(fun f g h i (x,y,z,w) ->
                             f x+g y+h z+i w) a.small b.small c.small d.small)
    ?print:(_opt_map_4 ~f:Print.quad a.print b.print c.print d.print)
    ~shrink:(Shrink.quad (_opt_or a.shrink Shrink.nil)
                   (_opt_or b.shrink Shrink.nil)
       (_opt_or c.shrink Shrink.nil)
       (_opt_or d.shrink Shrink.nil))
    (Gen.quad a.gen b.gen c.gen d.gen)

let option a =
  let g = Gen.opt a.gen
  and shrink = _opt_map a.shrink ~f:Shrink.option
  and small =
    _opt_map_or a.small ~d:(function None -> 0 | Some _ -> 1)
      ~f:(fun f o -> match o with None -> 0 | Some x -> f x)
  in
  make
    ~small
    ?shrink
    ?print:(_opt_map ~f:Print.option a.print)
    g

let map ?rev f a =
  make
    ?print:(_opt_map_2 rev a.print ~f:(fun r p x -> p (r x)))
    ?small:(_opt_map_2 rev a.small ~f:(fun r s x -> s (r x)))
    ?shrink:(_opt_map_2 rev a.shrink ~f:(fun r g x -> Iter.(g (r x) >|= f)))
    ?collect:(_opt_map_2 rev a.collect ~f:(fun r f x -> f (r x)))
    (fun st -> f (a.gen st))


(* TODO: explain black magic in this!! *)
let fun1_unsafe : 'a arbitrary -> 'b arbitrary -> ('a -> 'b) arbitrary =
  fun a1 a2 ->
    let magic_object = Obj.magic (object end) in
    let gen : ('a -> 'b) Gen.t = fun st ->
      let h = Hashtbl.create 10 in
      fun x ->
        if x == magic_object then
          Obj.magic h
        else
          try Hashtbl.find h x
          with Not_found ->
            let b = a2.gen st in
            Hashtbl.add h x b;
            b in
    let pp : (('a -> 'b) -> string) option = _opt_map_2 a1.print a2.print ~f:(fun p1 p2 f ->
      let h : ('a, 'b) Hashtbl.t = Obj.magic (f magic_object) in
      let b = Buffer.create 20 in
      Hashtbl.iter (fun key value -> Printf.bprintf b "%s -> %s; " (p1 key) (p2 value)) h;
      "{" ^ Buffer.contents b ^ "}"
    ) in
    make
      ?print:pp
      gen

let fun2_unsafe gp1 gp2 gp3 = fun1_unsafe gp1 (fun1_unsafe gp2 gp3)

module Poly_tbl : sig
  type ('a, 'b) t

  val create: 'a Observable.t -> 'b arbitrary -> int -> ('a, 'b) t Gen.t
  val get : ('a, 'b) t -> 'a -> 'b option
  val size : ('b -> int) -> (_, 'b) t -> int
  val shrink1 : ('a, 'b) t Shrink.t
  val shrink2 : 'b Shrink.t -> ('a, 'b) t Shrink.t
  val print : (_,_) t Print.t
end = struct
  type ('a, 'b) t = {
    get : 'a -> 'b option;
    p_size: ('b->int) -> int;
    p_shrink1: ('a, 'b) t Iter.t;
    p_shrink2: 'b Shrink.t -> ('a, 'b) t Iter.t;
    p_print: unit -> string;
  }

  let create (type k)(type v) k v size st : (k,v) t =
    let module T = Hashtbl.Make(struct
        type t = k
        let equal = k.Observable.eq
        let hash = k.Observable.hash
      end) in
    (* make a table
       @param extend if true, extend table on the fly *)
    let rec make ~extend tbl = {
      get=(fun x ->
        try Some (T.find tbl x)
        with Not_found ->
          if extend then (
            let v = v.gen st in
            T.add tbl x v;
            Some v
          ) else None);
      p_print=(fun () -> match v.print with
        | None -> "<fun>"
        | Some pp_v ->
          let b = Buffer.create 64 in
          T.iter
            (fun key value ->
               Printf.bprintf b "%s -> %s; "
                 (k.Observable.print key) (pp_v value))
            tbl;
        Buffer.contents b);
      p_shrink1=(fun yield ->
        (* remove bindings one by one *)
        T.iter
          (fun x _ ->
             let tbl' = T.copy tbl in
             T.remove tbl' x;
             yield (make ~extend:false tbl'))
          tbl);
      p_shrink2=(fun shrink_val yield ->
        (* shrink bindings one by one *)
        T.iter
          (fun x y ->
             shrink_val y
               (fun y' ->
                  let tbl' = T.copy tbl in
                  T.replace tbl' x y';
                  yield (make ~extend:false tbl')))
          tbl);
      p_size=(fun size_v -> T.fold (fun _ v n -> n + size_v v) tbl 0);
    } in
    make ~extend:true (T.create size)

  let get t x = t.get x
  let shrink1 t = t.p_shrink1
  let shrink2 p t = t.p_shrink2 p
  let print t = t.p_print ()
  let size p t = t.p_size p
end

(** Internal representation of functions *)
type (_, _) fun_repr =
  | Fun_ret : ('a, 'b) Poly_tbl.t * 'b arbitrary * 'b -> ('a -> 'b, 'b) fun_repr
  | Fun_append :
      ('a, ('f, 'ret) fun_repr) Poly_tbl.t *
      ('f, 'ret) fun_repr ->
      ('a -> 'f, 'ret) fun_repr

type (_, _) fun_gen =
  | Fun_gen_ret : 'a Observable.t * 'b arbitrary -> ('a -> 'b, 'b) fun_gen
  | Fun_gen_append : 'a Observable.t * ('b, 'ret) fun_gen -> ('a -> 'b, 'ret) fun_gen

type _ fun_ =
  | Fun : ('f, 'ret) fun_repr * 'f -> 'f fun_

(** Reifying functions *)
module Fn = struct
  type 'a t = 'a fun_

  let apply (Fun (_,f)) = f

  let make_
    : type a b. (a, b) fun_repr -> a fun_
    = fun r ->
      let rec aux
        : type a b. (a, b) fun_repr -> a
        = function
          | Fun_ret (tbl,_,def) ->
            (fun x -> match Poly_tbl.get tbl x with
               | None -> def
               | Some y -> y)
          | Fun_append (tbl,def) ->
            (fun x -> match Poly_tbl.get tbl x with
               | None -> aux def
               | Some y -> aux y)
      in
      Fun (r,aux r)

  let rec shrink_rep
    : type a b. (a,b) fun_repr Shrink.t
    = fun r ->
      let open Iter in
      match r with
        | Fun_ret (tbl,a,def) ->
          let sh_v = match a.shrink with None -> Shrink.nil | Some s->s in
          (Poly_tbl.shrink1 tbl >|= fun tbl' -> Fun_ret (tbl',a,def))
          <+>
          (sh_v def >|= fun def' -> Fun_ret (tbl,a,def'))
          <+>
          (Poly_tbl.shrink2 sh_v tbl >|= fun tbl' -> Fun_ret (tbl',a,def))
        | Fun_append (tbl,def) ->
          (Poly_tbl.shrink1 tbl >|= fun tbl' -> Fun_append (tbl',def))
          <+>
          (shrink_rep def >|= fun def' -> Fun_append (tbl,def'))
          <+>
          (Poly_tbl.shrink2 shrink_rep tbl >|= fun tbl' -> Fun_append (tbl',def))

  let shrink
    : type f. f fun_ Shrink.t
    = fun (Fun (rep,_)) ->
      let open Iter in
      shrink_rep rep >|= make_

  let rec size_rep : type a b. (a,b) fun_repr -> int = function
    | Fun_ret (tbl, a, def) ->
      let size_v x = match a.small with None -> 0 | Some f -> f x in
      Poly_tbl.size size_v tbl + size_v def
    | Fun_append (tbl, def) ->
      Poly_tbl.size size_rep tbl + size_rep def

  let size (Fun (rep,_)) = size_rep rep

  let print_rep f =
    let buf = Buffer.create 32 in
    let rec aux : type a ret. Buffer.t -> (a,ret) fun_repr -> unit
      = fun buf f -> match f with
        | Fun_ret (tbl,a,def) ->
          Printf.bprintf buf "{";
          Buffer.add_string buf (Poly_tbl.print tbl);
          Printf.bprintf buf "_ -> %s" (match a.print with
            | None -> "<opaque>"
            | Some s -> s def
          );
          Printf.bprintf buf "}";
        | Fun_append (tbl,def) ->
          Printf.bprintf buf "{";
          Buffer.add_string buf (Poly_tbl.print tbl);
          Printf.bprintf buf "_ -> %a" aux def;
          Printf.bprintf buf "}";
    in
    aux buf f;
    Buffer.contents buf

  let print (Fun (rep,_)) = print_rep rep

  let rec arb_rep
    : type a b. (a,b) fun_gen -> (a,b) fun_repr arbitrary
    = fun g ->
      make
        ~small:size_rep
        ~print:print_rep
        ~shrink:shrink_rep
        (gen_rep g)

  and gen_rep
    : type a b. (a,b) fun_gen -> (a,b) fun_repr Gen.t
    = fun g st -> match g with
      | Fun_gen_ret (o, arb) ->
        Fun_ret (Poly_tbl.create o arb 8 st, arb, arb.gen st)
      | Fun_gen_append (o, g') ->
        Fun_append
          (Poly_tbl.create o (arb_rep g') 8 st, gen_rep g' st)

  let gen g = Gen.map make_ (gen_rep g)
end

let (@@->) o arb = Fun_gen_ret (o,arb)

let (@->) o gen = Fun_gen_append (o,gen)

let fun_
  : type a b. (a,b) fun_gen -> a fun_ arbitrary
  = fun g ->
    make
      ~shrink:Fn.shrink
      ~print:Fn.print
      ~small:Fn.size
      (Fn.gen g)

let fun1 o1 ret = fun_ (o1 @@-> ret)
let fun2 o1 o2 ret = fun_ (o1 @-> o2 @@-> ret)
let fun3 o1 o2 o3 ret = fun_ (o1 @-> o2 @-> o3 @@-> ret)

(* Generator combinators *)

(** given a list, returns generator that picks at random from list *)
let oneofl ?print ?collect xs = make ?print ?collect (Gen.oneofl xs)
let oneofa ?print ?collect xs = make ?print ?collect (Gen.oneofa xs)

(** Given a list of generators, returns generator that randomly uses one of the generators
    from the list *)
let oneof l =
  let gens = List.map (fun a->a.gen) l in
  let first = List.hd l in
  let print = first.print
  and small = first.small
  and collect = first.collect
  and shrink = first.shrink in
  make ?print ?small ?collect ?shrink (Gen.oneof gens)

(** Generator that always returns given value *)
let always ?print x =
  let gen _st = x in
  make ?print gen

(** like oneof, but with weights *)
let frequency ?print ?small ?shrink ?collect l =
  let first = snd (List.hd l) in
  let small = _opt_sum small first.small in
  let print = _opt_sum print first.print in
  let shrink = _opt_sum shrink first.shrink in
  let collect = _opt_sum collect first.collect in
  let gens = List.map (fun (x,y) -> x, y.gen) l in
  make ?print ?small ?shrink ?collect (Gen.frequency gens)

(** Given list of [(frequency,value)] pairs, returns value with probability proportional
    to given frequency *)
let frequencyl ?print ?small l = make ?print ?small (Gen.frequencyl l)
let frequencya ?print ?small l = make ?print ?small (Gen.frequencya l)

let map_same_type f a =
  adapt_ a (fun st -> f (a.gen st))

let map_keep_input ?print ?small f a =
  make
    ?print:(match print, a.print with
        | Some f1, Some f2 -> Some (Print.pair f2 f1)
        | Some f, None -> Some (Print.comap snd f)
        | None, Some f -> Some (Print.comap fst f)
        | None, None -> None)
    ?small:(match small, a.small with
        | Some f, _ -> Some (fun (_,y) -> f y)
        | None, Some f -> Some (fun (x,_) -> f x)
        | None, None -> None)
    Gen.(map_keep_input f a.gen)

module TestResult = struct
  type 'a counter_ex = {
    instance: 'a; (** The counter-example(s) *)
    shrink_steps: int; (** How many shrinking steps for this counterex *)
  }

  type 'a failed_state = 'a counter_ex list

  type 'a state =
    | Success
    | Failed of 'a failed_state (** Failed instances *)
    | Error of 'a counter_ex * exn * string (** Error, backtrace, and instance
                                                that triggered it *)

  (* result returned by running a test *)
  type 'a t = {
    mutable state : 'a state;
    mutable count: int;  (* number of tests *)
    mutable count_gen: int; (* number of generated cases *)
    collect_tbl: (string, int) Hashtbl.t lazy_t;
    stats_tbl: ('a stat * (int, int) Hashtbl.t) list;
  }

  (* indicate failure on the given [instance] *)
  let fail ~small ~steps:shrink_steps res instance =
    let c_ex = {instance; shrink_steps; } in
    match res.state with
    | Success -> res.state <- Failed [ c_ex ]
    | Error (x, e, bt) ->
        res.state <- Error (x,e,bt); (* same *)
    | Failed [] -> assert false
    | Failed (c_ex' :: _ as l) ->
        match small with
        | Some small ->
            (* all counter-examples in [l] have same size according to [small],
               so we just compare to the first one, and we enforce
               the invariant *)
            begin match Pervasives.compare (small instance) (small c_ex'.instance) with
            | 0 -> res.state <- Failed (c_ex :: l) (* same size: add [c_ex] to [l] *)
            | n when n<0 -> res.state <- Failed [c_ex] (* drop [l] *)
            | _ -> () (* drop [c_ex], not small enough *)
            end
        | _ ->
            (* no [small] function, keep all counter-examples *)
            res.state <-
              Failed (c_ex :: l)

  let error ~steps res instance e bt =
    res.state <- Error ({instance; shrink_steps=steps}, e, bt)

  let collect r =
    if Lazy.is_val r.collect_tbl then None else Some (Lazy.force r.collect_tbl)

  let stats r = r.stats_tbl
end

module Test = struct
  type 'a cell = {
    count : int; (* number of tests to do *)
    long_factor : int; (* multiplicative factor for long test count *)
    max_gen : int; (* max number of instances to generate (>= count) *)
    max_fail : int; (* max number of failures *)
    law : 'a -> bool; (* the law to check *)
    arb : 'a arbitrary; (* how to generate/print/shrink instances *)
    mutable name : string; (* name of the law *)
  }

  type t = | Test : 'a cell -> t

  let get_name {name; _} = name
  let set_name c name = c.name <- name
  let get_law {law; _} = law
  let get_arbitrary {arb; _} = arb

  let get_count {count; _ } = count
  let get_long_factor {long_factor; _} = long_factor

  let default_count = 100

  let fresh_name =
    let r = ref 0 in
    (fun () -> incr r; Printf.sprintf "anon_test_%d" !r)

  let make_cell ?(count=default_count) ?(long_factor=1) ?max_gen
  ?(max_fail=1) ?small ?(name=fresh_name()) arb law
  =
    let max_gen = match max_gen with None -> count + 200 | Some x->x in
    let arb = match small with None -> arb | Some f -> set_small f arb in
    {
      law;
      arb;
      max_gen;
      max_fail;
      name;
      count;
      long_factor;
    }

  let make ?count ?long_factor ?max_gen ?max_fail ?small ?name arb law =
    Test (make_cell ?count ?long_factor ?max_gen ?max_fail ?small ?name arb law)


  (** {6 Running the test} *)

  module R = TestResult

  (* Result of an instance run *)
  type res =
    | Success
    | Failure
    | FalseAssumption
    | Error of exn * string

  (* Step function, called after each instance test *)
  type 'a step = string -> 'a cell -> 'a -> res -> unit

  let step_nil_ _ _ _ _ = ()

  (* state required by {!check} to execute *)
  type 'a state = {
    test: 'a cell;
    step: 'a step;
    rand: Random.State.t;
    mutable res: 'a TestResult.t;
    mutable cur_count: int;  (** number of iterations to do *)
    mutable cur_max_gen: int; (** maximum number of generations allowed *)
    mutable cur_max_fail: int; (** maximum number of counter-examples allowed *)
  }

  let is_done state = state.cur_count <= 0 || state.cur_max_gen <= 0

  let decr_count state =
    state.res.R.count <- state.res.R.count + 1;
    state.cur_count <- state.cur_count - 1

  let new_input state =
    state.res.R.count_gen <- state.res.R.count_gen + 1;
    state.cur_max_gen <- state.cur_max_gen - 1;
    state.test.arb.gen state.rand

  (* statistics on inputs *)
  let collect st i = match st.test.arb.collect with
    | None -> ()
    | Some f ->
        let key = f i in
        let (lazy tbl) = st.res.R.collect_tbl in
        let n = try Hashtbl.find tbl key with Not_found -> 0 in
        Hashtbl.replace tbl key (n+1)

  let update_stats st i =
    List.iter
      (fun ((_,f), tbl) ->
         let key = f i in
         assert (key>=0);
         let n = try Hashtbl.find tbl key with Not_found -> 0 in
         Hashtbl.replace tbl key (n+1))
      st.res.R.stats_tbl

  (* try to shrink counter-ex [i] into a smaller one. Returns
     shrinked value and number of steps *)
  let shrink st i =
    let rec shrink_ st i ~steps = match st.test.arb.shrink with
      | None -> i, steps
      | Some f ->
        let i' = Iter.find
          (fun x ->
            try
              not (st.test.law x)
            with FailedPrecondition -> false
            | _ -> true (* fail test (by error) *)
          ) (f i)
        in
        match i' with
        | None -> i, steps
        | Some i' -> shrink_ st i' ~steps:(steps+1) (* shrink further *)
    in
    shrink_ ~steps:0 st i

  type 'a check_result =
    | CR_continue
    | CR_yield of 'a TestResult.t

  (* test raised [e] on [input]; try to shrink then fail *)
  let handle_exn state input e bt : _ check_result =
    (* first, shrink
       TODO: shall we shrink differently (i.e. expected only an error)? *)
    let input, steps = shrink state input in
    state.step state.test.name state.test input (Error (e, bt));
    R.error state.res ~steps input e bt;
    CR_yield state.res

  (* test failed on [input], which means the law is wrong. Continue if
     we should. *)
  let handle_fail state input : _ check_result =
    (* first, shrink *)
    let input, steps = shrink state input in
    (* fail *)
    decr_count state;
    state.step state.test.name state.test input Failure;
    state.cur_max_fail <- state.cur_max_fail - 1;
    R.fail ~small:state.test.arb.small state.res ~steps input;
    if _is_some state.test.arb.small && state.cur_max_fail > 0
    then CR_continue
    else CR_yield state.res

  (* [check_state state] applies [state.test] repeatedly ([iter] times)
      on output of [test.rand], and if [state.test] ever returns false,
      then the input that caused the failure is returned in [Failed].
      If [func input] raises [FailedPrecondition] then  the input is discarded, unless
         max_gen is 0. *)
  let rec check_state state =
    if is_done state then state.res
    else (
      let input = new_input state in
      collect state input;
      update_stats state input;
      let res =
        try
          if state.test.law input
          then (
            (* one test ok *)
            decr_count state;
            state.step state.test.name state.test input Success;
            CR_continue
          ) else handle_fail state input
        with
        | FailedPrecondition ->
          state.step state.test.name state.test input FalseAssumption;
          CR_continue
        | e ->
          let bt = Printexc.get_backtrace () in
          handle_exn state input e bt
      in
      match res with
        | CR_continue -> check_state state
        | CR_yield x -> x
    )

  type 'a callback = string -> 'a cell -> 'a TestResult.t -> unit

  let callback_nil_ _ _ _ = ()

  (* main checking function *)
  let check_cell ?(long=false) ?(call=callback_nil_) ?(step=step_nil_)
      ?(rand=Random.State.make [| 0 |]) cell =
    let factor = if long then cell.long_factor else 1 in
    let state = {
      test=cell;
      rand; step;
      cur_count=factor*cell.count;
      cur_max_gen=factor*cell.max_gen;
      cur_max_fail=factor*cell.max_fail;
      res = {R.
        state=R.Success; count=0; count_gen=0;
        collect_tbl=lazy (Hashtbl.create 10);
        stats_tbl= List.map (fun stat -> stat, Hashtbl.create 10) cell.arb.stats;
      };
    } in
    let res = check_state state in
    call cell.name cell res;
    res

  exception Test_fail of string * string list
  exception Test_error of string * string * exn * string

  (* print instance using [arb] *)
  let print_instance arb i = match arb.print with
    | None -> "<instance>"
    | Some pp -> pp i

  let print_c_ex arb c =
    if c.R.shrink_steps > 0
    then Printf.sprintf "%s (after %d shrink steps)"
      (print_instance arb c.R.instance) c.R.shrink_steps
    else print_instance arb c.R.instance

  let pp_print_test_fail name out l =
    let rec pp_list out = function
      | [] -> ()
      | [x] -> Format.fprintf out "%s@," x
      | x :: y -> Format.fprintf out "%s@,%a" x pp_list y
    in
    Format.fprintf out "@[<hv2>test `%s`@ failed on ≥ %d cases:@ @[<v>%a@]@]"
      name (List.length l) pp_list l

  let asprintf fmt =
    let buf = Buffer.create 128 in
    let out = Format.formatter_of_buffer buf in
    Format.kfprintf (fun _ -> Buffer.contents buf) out fmt

  let print_test_fail name l = asprintf "@[<2>%a@]@?" (pp_print_test_fail name) l

  let print_test_error name i e stack =
    Format.sprintf "@[test `%s`@ raised exception `%s`@ on `%s`@,%s@]"
      name (Printexc.to_string e) i stack

  let print_collect c =
    let out = Buffer.create 64 in
    Hashtbl.iter
      (fun case num -> Printf.bprintf out "%s: %d cases\n" case num) c;
    Buffer.contents out

  let stat_max_lines = 20 (* maximum number of lines for a histogram *)

  let print_stat ((name,_), tbl) =
    let avg = ref 0. in
    let num = ref 0 in
    let max_idx =
      Hashtbl.fold
        (fun i res m ->
           avg := !avg +. float_of_int (i * res);
           num := !num + res;
           max i m)
        tbl 0
    in
    if !num > 0 then (
      avg := !avg /. float_of_int !num
    );
    (* compute average *)
    (* group by buckets, if there are too many entries *)
    let hist_size, bucket_size =
      if max_idx > stat_max_lines
      then 1+stat_max_lines, int_of_float (ceil (float_of_int max_idx/. float_of_int stat_max_lines))
      else 1+max_idx, 1
    in
    let max_val = ref 0 in (* max value after grouping by buckets *)
    let rows =
      Array.init hist_size
        (fun i ->
           let n = ref 0 in
           let i' = i * bucket_size in
           for j=i' to i'+bucket_size-1 do
             n := !n + (try Hashtbl.find tbl j with Not_found -> 0)
           done;
           max_val := max !max_val !n;
           let key =
             if bucket_size=1
             then Printf.sprintf "%d" i
             else Printf.sprintf "%d-%d" i' (i'+bucket_size-1)
           in
           key, !n)
    in
    (* entries of the table, sorted by increasing index *)
    let out = Buffer.create 128 in
    Printf.bprintf out "stats %s:\n" name;
    Printf.bprintf out "  num: %d, avg: %.2f\n" !num !avg;
    Array.iter
      (fun (key, value) ->
         (* NOTE: keep in sync *)
         let m = value * 55 / !max_val in
         Printf.bprintf out "  %8s: %-56s %10d\n" key (String.make m '#') value)
      rows;
    Buffer.contents out

  let () = Printexc.register_printer
    (function
      | Test_fail (name,l) -> Some (print_test_fail name l)
      | Test_error (name,i,e,st) -> Some (print_test_error name i e st)
      | _ -> None)

  let print_fail arb name l =
    print_test_fail name (List.map (print_c_ex arb) l)

  let print_error ?(st="") arb name (i,e) =
    print_test_error name (print_c_ex arb i) e st

  let check_result cell res = match res.R.state with
    | R.Success -> ()
    | R.Error (i,e, bt) ->
      raise (Test_error (cell.name, print_c_ex cell.arb i, e, bt))
    | R.Failed l ->
        let l = List.map (print_c_ex cell.arb) l in
        raise (Test_fail (cell.name, l))

  let check_cell_exn ?long ?call ?step ?rand cell =
    let res = check_cell ?long ?call ?step ?rand cell in
    check_result cell res

  let check_exn ?long ?rand (Test cell) = check_cell_exn ?long ?rand cell
end
