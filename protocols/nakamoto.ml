open Cpr_lib
open Protocol

type block = { height : int }

let dag_roots = [ { height = 0 } ]

let dag_invariant ~pow ~parents ~child =
  match pow, parents with
  | true, [ p ] -> child.height = p.height + 1
  | _ -> false
;;

let init ~roots =
  match roots with
  | [ genesis ] -> genesis
  | _ -> failwith "invalid roots"
;;

let have_common_ancestor ctx =
  let rec h a b =
    if a == b
    then true
    else (
      let a' = ctx.data a
      and b' = ctx.data b in
      if a'.height = b'.height
      then (
        match Dag.parents ctx.view a, Dag.parents ctx.view b with
        | [ a ], [ b ] -> h a b
        | [], _ | _, [] -> false
        | _ -> failwith "invalid dag")
      else if a'.height > b'.height
      then (
        match Dag.parents ctx.view a with
        | [ a ] -> h a b
        | [] -> false
        | _ -> failwith "invalid dag")
      else (
        match Dag.parents ctx.view b with
        | [ b ] -> h a b
        | [] -> false
        | _ -> failwith "invalid dag"))
  in
  h
;;

let leaves view gnode =
  let rec h acc gnode =
    match Dag.children view gnode with
    | [] -> gnode :: acc
    | l -> List.fold_left h acc l
  in
  h [] gnode
;;

let event_handler ctx preferred = function
  | Activate pow ->
    let head = ctx.data preferred in
    let head' = ctx.extend_dag ~pow [ preferred ] { height = head.height + 1 } in
    ctx.release head';
    head'
  | Deliver gnode ->
    (* Only consider gnode if its heritage is visible. *)
    if have_common_ancestor ctx gnode preferred
    then (
      let consider preferred gnode =
        let node = ctx.data gnode
        and head = ctx.data preferred in
        if node.height > head.height then gnode else preferred
      in
      (* delayed gnode might connect nodes delivered previously *)
      List.fold_left consider preferred (leaves ctx.view gnode))
    else preferred
;;

let protocol : _ protocol = { init; dag_roots; dag_invariant; event_handler }

let%test _ =
  let open Simulator in
  let params =
    { n_nodes = 32; n_activations = 1000; activation_delay = 10.; message_delay = 1. }
  in
  init params protocol
  |> loop params
  |> fun { node_state; _ } ->
  Array.for_all
    (fun pref ->
      (Dag.data pref).value.height > 900
      (* more than 900 blocks in a sequence imply less than 10% orphans. *))
    node_state
;;
