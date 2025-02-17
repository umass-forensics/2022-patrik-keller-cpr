(* proof of work -- invalidated on first use *)
type pow = { mutable fresh : bool }

let pow () = { fresh = true }

(* data attached to each DAG vertex *)
type 'a data =
  { value : 'a
  ; received_at : floatarray
  ; delivered_at : floatarray
        (* delivery happens when all dependencies in the DAG are fulfilled *)
  ; appended_by : int option
  ; appended_at : float
  ; mutable released_at : float
  ; pow_hash : (int * int) option
  ; signed_by : int option
  }

type 'prot_data event =
  { node : int
  ; event : ('prot_data data, pow) Intf.event
  }

type 'prot_data clock =
  { mutable now : float
  ; mutable queue : (float, 'prot_data event) OrderedQueue.t
  ; mutable c_activations : int
  }

type ('prot_data, 'node_state) node' =
  { mutable state : 'node_state
  ; mutable n_activations : int
  ; handler : 'node_state -> ('prot_data data, pow) Intf.event -> 'node_state
  ; preferred : 'node_state -> 'prot_data data Dag.vertex
  }

type 'prot_data node = Node : ('prot_data, 'node_state) node' -> 'prot_data node

type 'prot_data state =
  { clock : 'prot_data clock
  ; dag : 'prot_data data Dag.t
  ; global : ('prot_data data, 'prot_data) Intf.global_view
  ; nodes : 'prot_data node array
  ; assign_pow_distr : int Distributions.iid
  ; activation_delay_distr : float Distributions.iid
  ; network : Network.t
  }

type wrapped_protocol =
  | Protocol : ('dag_data data, 'dag_data, pow, 'state) Intf.protocol -> wrapped_protocol

let schedule time delay event =
  time.queue <- OrderedQueue.queue (time.now +. delay) event time.queue
;;

let schedule_activation state =
  let delay = Distributions.sample state.activation_delay_distr
  and node = Distributions.sample state.assign_pow_distr in
  schedule state.clock delay { node; event = Activate (pow ()) }
;;

let disseminate network clock source x =
  let open Network in
  List.iter
    (fun link ->
      let received_at = (Dag.data x).received_at in
      let t = Float.Array.get received_at link.dest
      and delay = Distributions.sample link.delay in
      let t' = clock.now +. delay in
      if t' < t
      then (
        (* only schedule event if it enables faster delivery *)
        Float.Array.set received_at link.dest t';
        schedule clock delay { node = link.dest; event = Deliver x }))
    network.nodes.(source).links
;;

let spawn (n : _ Intf.node') ~roots actions =
  { handler = n.handler actions
  ; state = n.init ~roots
  ; preferred = n.preferred
  ; n_activations = 0
  }
;;

let string_of_pow_hash (nonce, _serial) =
  Printf.sprintf "%.3f" (float_of_int nonce /. (2. ** 29.))
;;

let all_honest (network : Network.t) (protocol : _ Intf.protocol)
    : _ state * _ Dag.vertex list * (_ Intf.local_view * _ Intf.actions) array
  =
  let n_nodes = Array.length network.nodes in
  let dag = Dag.create () in
  let roots =
    let delivered_at = Float.Array.make n_nodes 0.
    and received_at = Float.Array.make n_nodes 0. in
    List.map
      (fun value ->
        Dag.append
          dag
          []
          { value
          ; delivered_at
          ; received_at
          ; appended_by = None
          ; appended_at = 0.
          ; released_at = 0.
          ; signed_by = None
          ; pow_hash = None
          })
      protocol.dag_roots
  in
  let clock = { queue = OrderedQueue.init Float.compare; now = 0.; c_activations = 0 }
  and global : _ Intf.global_view =
    let data n = (Dag.data n).value
    and signed_by n = (Dag.data n).signed_by
    and pow_hash n = (Dag.data n).pow_hash in
    { view = Dag.view dag; data; signed_by; pow_hash }
  in
  let views_actions =
    Array.init n_nodes (fun node ->
        let view =
          Dag.filter
            (fun x -> Float.Array.get (Dag.data x).delivered_at node <= clock.now)
            global.view
        and delivered_at n = Float.Array.get (Dag.data n).delivered_at node
        and appended_by_me n = (Dag.data n).appended_by = Some node
        and share n =
          let d = Dag.data n in
          d.released_at <- min d.released_at clock.now;
          disseminate network clock node n
        and released n = (Dag.data n).released_at <= clock.now
        and extend_dag ?pow ?(sign = false) parents child =
          let pow_hash =
            (* check pow *)
            match pow with
            | Some x when x.fresh ->
              x.fresh <- false;
              (* ensure uniqueness of pow hashes *)
              Some (Random.bits (), Dag.size dag)
            | Some _ -> raise (Invalid_argument "pow was used before")
            | None -> None
          in
          let node =
            Dag.append
              dag
              parents
              { value = child
              ; received_at =
                  Float.Array.init n_nodes (fun i ->
                      if i = node then clock.now else Float.infinity)
              ; delivered_at =
                  Float.Array.init n_nodes (fun i ->
                      if i = node then clock.now else Float.infinity)
              ; appended_at = clock.now
              ; appended_by = Some node
              ; pow_hash
              ; signed_by = (if sign then Some node else None)
              ; released_at = Float.infinity
              }
          in
          if not (protocol.dag_validity global node)
          then (
            (* We guarantee that invalid extensions are never delivered elsewhere *)
            let info x =
              [ protocol.describe x.value, ""
              ; ( "node"
                , Option.map string_of_int x.appended_by |> Option.value ~default:"n/a" )
              ; "time", Printf.sprintf "%.2f" x.appended_at
              ; ( "hash"
                , Option.map string_of_pow_hash x.pow_hash |> Option.value ~default:"n/a"
                )
              ]
            in
            Dag.Exn.raise global.view info [ node ] "invalid append");
          node
        in
        (* TODO breakout and reuse for RL gyms *)
        let view : _ Intf.local_view =
          { my_id = node
          ; view
          ; data = global.data
          ; signed_by = global.signed_by
          ; pow_hash = global.pow_hash
          ; delivered_at
          ; released
          ; appended_by_me
          }
        and actions : _ Intf.actions = { share; extend_dag } in
        view, actions)
  and assign_pow_distr =
    let weights =
      Array.map (fun x -> Network.(x.compute)) network.nodes |> Array.to_list
    in
    Distributions.discrete ~weights
  and activation_delay_distr = Distributions.exponential ~ev:network.activation_delay in
  let nodes =
    Array.map
      (fun (view, actions) -> Node (spawn (protocol.honest view) ~roots actions))
      views_actions
  in
  let state =
    { clock; dag; global; nodes; assign_pow_distr; activation_delay_distr; network }
  in
  schedule_activation state;
  state, roots, views_actions
;;

let patch ~node impl (state, roots, views_actions) =
  let (view : _ Intf.local_view), (actions : _ Intf.actions) = views_actions.(node) in
  let n = spawn (impl view) ~roots actions in
  state.nodes.(node) <- Node n;
  view, actions, n
;;

(* TODO hide second and third element *)
let init (state, _roots, _views_actions) = state

let handle_event ~activations state ev =
  let (Node node) = state.nodes.(ev.node) in
  let was_delivered n =
    Float.Array.get (Dag.data n).delivered_at ev.node <= state.clock.now
  and was_received n = Float.Array.get (Dag.data n).received_at ev.node <= state.clock.now
  and disseminate =
    match state.network.dissemination with
    | Flooding -> disseminate state.network state.clock ev.node
    | Simple -> fun _n -> ()
  in
  match ev.event with
  | Activate _pow ->
    state.clock.c_activations <- state.clock.c_activations + 1;
    node.n_activations <- node.n_activations + 1;
    (* check ending condition; schedule next activation *)
    if state.clock.c_activations < activations || activations < 0
    then schedule_activation state;
    (* apply event handler *)
    node.state <- node.handler node.state ev.event
  | Deliver n ->
    (* deliver DAG vertex exactly once to each network node as soon as all parent DAG
       vertices have been delivered *)
    if was_delivered n
    then (* n was delivered before *) ()
    else if List.exists
              (fun n -> was_delivered n |> not)
              (Dag.parents state.global.view n)
    then (* dependencies are not yet fulfilled *) ()
    else (
      (* deliver; continue broadcast; recurse *)
      Float.Array.set (Dag.data n).delivered_at ev.node state.clock.now;
      node.state <- node.handler node.state ev.event;
      disseminate n;
      (* recursive delivery of now unlocked dependent DAG vertices *)
      List.iter
        (fun n ->
          if was_received n && not (was_delivered n)
          then schedule state.clock 0. { node = ev.node; event = Deliver n })
        (Dag.children state.global.view n))
;;

let dequeue state =
  OrderedQueue.dequeue state.clock.queue
  |> Option.map (fun (now, ev, queue) ->
         assert (now >= state.clock.now);
         state.clock.now <- now;
         state.clock.queue <- queue;
         ev)
;;

let rec loop ~activations state =
  match dequeue state with
  | None -> ()
  | Some ev ->
    handle_event ~activations state ev;
    loop ~activations state
;;

let apply_reward_function' (fn : _ Intf.reward_function) seq state =
  let arr = Array.make (Array.length state.nodes) 0. in
  let assign x n =
    match (Dag.data n).appended_by with
    | Some i -> arr.(i) <- arr.(i) +. x
    | None -> ()
  and view = state.global in
  Seq.iter (fn ~view ~assign) seq;
  arr
;;

let apply_reward_function (fn : _ Intf.reward_function) head state =
  apply_reward_function' fn (Dag.iterate_ancestors state.global.view [ head ]) state
;;
