(***********************************************************************)
(*                                                                     *)
(*                         Caml Special Light                          *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1995 Institut National de Recherche en Informatique et   *)
(*  Automatique.  Distributed only by permission.                      *)
(*                                                                     *)
(***********************************************************************)

(* $Id$ *)

(* Register allocation by coloring of the interference graph *)

open Reg

(* Preallocation of spilled registers in the stack. *)

let allocate_spilled reg =
  if reg.spill then begin
    let class = Proc.register_class reg in
    let nslots = Proc.num_stack_slots.(class) in
    let conflict = Array.new nslots false in
    List.iter
      (fun r ->
        match r.loc with
          Stack(Local n) ->
            if Proc.register_class r = class then conflict.(n) <- true
        | _ -> ())
      reg.interf;
    let slot = ref 0 in
    while !slot < nslots & conflict.(!slot) do incr slot done;
    reg.loc <- Stack(Local !slot);
    if !slot >= nslots then Proc.num_stack_slots.(class) <- !slot + 1
  end

(* Compute the degree (= number of neighbours of the same type)
   of each register, and split them in two sets:
   unconstrained (degree < number of available registers)
   and constrained (degree >= number of available registers).
   Spilled registers are ignored in the process. *)

let unconstrained = ref Reg.Set.empty
let constrained = ref Reg.Set.empty

let find_degree reg =
  if reg.spill then () else begin
    let deg = ref 0 in
    let class = Proc.register_class reg in
    List.iter
      (fun r -> if not r.spill & Proc.register_class r = class then incr deg)
      reg.interf;
    reg.degree <- !deg;
    if !deg >= Proc.num_available_registers.(class)
    then constrained := Reg.Set.add reg !constrained
    else unconstrained := Reg.Set.add reg !unconstrained
  end

(* Remove a register from the interference graph *)

let remove_reg reg =
  reg.degree <- 0;   (* 0 means r is no longer part of the graph *)
  let class = Proc.register_class reg in
  List.iter
    (fun r ->
      if Proc.register_class r = class & r.degree > 0 then begin
        let olddeg = r.degree in
        r.degree <- olddeg - 1;
        if olddeg = Proc.num_available_registers.(class) then begin
          (* r was constrained and becomes unconstrained *)
          constrained := Reg.Set.remove r !constrained;
          unconstrained := Reg.Set.add r !unconstrained
        end
      end)
    reg.interf

(* Remove all registers one by one, unconstrained if possible, otherwise
   constrained with lowest spill cost. Return the list of registers removed
   in reverse order.
   The spill cost measure is [r.spill_cost / r.degree].
   [r.spill_cost] estimates the number of accesses to this register. *)

let rec remove_all_regs stack =
  if not (Reg.Set.is_empty !unconstrained) then begin
    (* Pick any unconstrained register *)
    let r = Reg.Set.choose !unconstrained in
    unconstrained := Reg.Set.remove r !unconstrained;
    remove_all_regs (r :: stack)
  end else
  if not (Reg.Set.is_empty !constrained) then begin
    (* Find a constrained reg with minimal cost *)
    let r = ref Reg.dummy in
    let min_degree = ref 0 and min_spill_cost = ref 1 in
      (* initially !min_spill_cost / !min_degree is +infty *)
    Reg.Set.iter
      (fun r2 ->
        (* if r2.spill_cost / r2.degree < !min_spill_cost / !min_degree *)
        if r2.spill_cost * !min_degree < !min_spill_cost * r2.degree
        then begin
          r := r2; min_degree := r2.degree; min_spill_cost := r2.spill_cost
        end)
      !constrained;
    constrained := Reg.Set.remove !r !constrained;
    remove_all_regs (!r :: stack)
  end else
    stack                             (* All regs have been removed *)

(* Iterate over all registers preferred by the given register (transitively) *)

let iter_preferred f reg =
  let rec walk r w =
    if not r.visited then begin
      f r w;
      begin match r.prefer with
          [] -> ()
        | p  -> r.visited <- true;
                List.iter (fun (r1, w1) -> walk r1 (min w w1)) p;
                r.visited <- false
      end
    end in
  reg.visited <- true;
  List.iter (fun (r, w) -> walk r w) reg.prefer;
  reg.visited <- false

(* Where to start the search for a suitable register. 
   Used to introduce some "randomness" in the choice between registers
   with equal scores. This offers more opportunities for scheduling. *)

let start_register = Array.new Proc.num_register_classes 0

(* Assign a location to a register, the best we can *)

let assign_location reg =
  let class = Proc.register_class reg in
  let first_reg = Proc.first_available_register.(class) in
  let num_regs = Proc.num_available_registers.(class) in
  let last_reg = first_reg + num_regs in
  let score = Array.new num_regs 0 in
  (* Favor the registers that have been assigned to pseudoregs for which
     we have a preference. If these pseudoregs have not been assigned
     already, avoid the registers with which they conflict. *)
  iter_preferred
    (fun r w ->
      match r.loc with
        Reg n -> if n >= first_reg & n < last_reg then
                   score.(n - first_reg) <- score.(n - first_reg) + w
      | Unknown ->
          List.iter
            (fun neighbour ->
              match neighbour.loc with
                Reg n -> if n >= first_reg & n < last_reg then
                         score.(n - first_reg) <- score.(n - first_reg) - w
              | _ -> ())
            r.interf
      | _ -> ())
    reg;
  List.iter
    (fun neighbour ->
      (* Prohibit the registers that have been assigned
         to our neighbours *)
      begin match neighbour.loc with
        Reg n -> if n >= first_reg & n < last_reg then
                   score.(n - first_reg) <- (-1000000)
      | _ -> ()
      end;
      (* Avoid the registers that have been assigned to pseudoregs
         for which our neighbours have a preference *)
      iter_preferred
        (fun r w ->
          match r.loc with
            Reg n -> if n >= first_reg & n < last_reg then
                       score.(n - first_reg) <- score.(n - first_reg) - (w - 1)
                     (* w-1 to break the symmetry when two conflicting regs
                        have the same preference for a third reg. *)
          | _ -> ())
        neighbour)
    reg.interf;
  (* Pick the register with the best score *)
  let best_score = ref (-1000000) and best_reg = ref (-1) in
  let start = start_register.(class) in
  for n = start to num_regs - 1 do
    if score.(n) > !best_score then begin
      best_score := score.(n);
      best_reg := n
    end
  done;
  for n = 0 to start - 1 do
    if score.(n) > !best_score then begin
      best_score := score.(n);
      best_reg := n
    end
  done;
  (* Found a register? *)
  if !best_reg >= 0 then begin
    reg.loc <- Reg(first_reg + !best_reg);
    start_register.(class) <- (if start + 1 >= num_regs then 0 else start + 1)
  end else begin
    (* Sorry, we must put the pseudoreg in a stack location *)
    (* First, check if we have a preference for an incoming location
       we do not conflict with. *)
    let best_score = ref 0 and best_incoming_loc = ref (-1) in
    List.iter
      (fun (r, w) ->
        match r.loc with
          Stack(Incoming n) ->
            if w > !best_score
             & List.for_all (fun neighbour -> neighbour.loc <> r.loc)
                            reg.interf
            then begin
              best_score := w;
              best_incoming_loc := n
            end
        | _ -> ())
      reg.prefer;
    if !best_incoming_loc >= 0 then
      reg.loc <- Stack(Incoming !best_incoming_loc)
    else begin
      (* Now, look for a location in the local area *)
      let nslots = Proc.num_stack_slots.(class) in
      let score = Array.new nslots 0 in
      (* Compute the scores as for registers *)
      List.iter
        (fun (r, w) ->
          match r.loc with
            Stack(Local n) -> if Proc.register_class r = class then
                              score.(n) <- score.(n) + w
          | Unknown ->
              List.iter
                (fun neighbour ->
                  match neighbour.loc with
                    Stack(Local n) ->
                      if Proc.register_class neighbour = class
                      then score.(n) <- score.(n) - w
                  | _ -> ())
                r.interf
          | _ -> ())
        reg.prefer;
      List.iter
        (fun neighbour ->
          begin match neighbour.loc with
              Stack(Local n) ->
                if Proc.register_class neighbour = class then
                score.(n) <- (-1000000)
          | _ -> ()
          end;
          List.iter
            (fun (r, w) ->
              match r.loc with
                Stack(Local n) -> if Proc.register_class r = class then
                                  score.(n) <- score.(n) - w
              | _ -> ())
            neighbour.prefer)
        reg.interf;
      (* Pick the location with the best score *)
      let best_score = ref (-1000000) and best_slot = ref (-1) in
      for n = 0 to nslots - 1 do
        if score.(n) > !best_score then begin
          best_score := score.(n);
          best_slot := n
        end
      done;
      (* Found one? *)
      if !best_slot >= 0 then
        reg.loc <- Stack(Local !best_slot)
      else begin
        (* Allocate a new stack slot *)
        reg.loc <- Stack(Local nslots);
        Proc.num_stack_slots.(class) <- nslots + 1
      end
    end
  end;
  (* Cancel the preferences of this register so that they don't influence
     transitively the allocation of registers that prefer this reg. *)
  reg.prefer <- []

let allocate_registers() =
  (* First pass: preallocate spill registers
     Second pass: compute the degrees
     Third pass: determine coloring order by successive removals of regs
     Fourth pass: assign registers in that order *)
  for i = 0 to Proc.num_register_classes - 1 do
    Proc.num_stack_slots.(i) <- 0;
    start_register.(i) <- 0
  done;
  List.iter allocate_spilled (Reg.all_registers());
  List.iter find_degree (Reg.all_registers());
  List.iter assign_location (remove_all_regs [])
