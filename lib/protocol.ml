type ('env, 'data, 'pow) actions =
  { share : 'env Dag.node -> unit
        (** Instruct the simulator to make the DAG node visible to other network nodes.
            The simulator might apply network delays depending on its configuration. *)
  ; extend_dag : ?pow:'pow -> 'env Dag.node list -> 'data -> 'env Dag.node
        (** [extend_dag ~pow parents data] adds a node with [data] to the simulator's DAG.
            Initially, only the extending network node can see the new node. The simulator
            raises {Invalid_argument} if the proposed extension does not satisfy the DAG
            invariant specified by the simulated protocol. *)
  }

(** Simulator events as they are applied to single network nodes *)
type ('env, 'pow) event =
  | Activate of 'pow
  | Deliver of 'env Dag.node

(** Behaviour of a single network node. Type of node local state is packed. *)
type ('env, 'data, 'pow) node =
  | Node :
      { init : roots:'env Dag.node list -> 'state
            (** Node initialization. The [roots] argument holds references to global
                versions of {protocol.dag_roots}. The roots are visible to all nodes from
                the beginning. *)
      ; handler : ('env, 'data, 'pow) actions -> 'state -> ('env, 'pow) event -> 'state
            (** Event handlers. May trigger side effects via [actions] argument. *)
      ; preferred : 'state -> 'env Dag.node
            (** Returns a node's preferred tip of the chain. *)
      }
      -> ('env, 'data, 'pow) node

type ('env, 'data) context =
  { view : 'env Dag.view
        (** View on the simulator's DAG. Partial visibility models the information set of
            the network node. *)
  ; read : 'env -> 'data
        (** Read the protocol data from simulator data attached to DAG nodes. *)
  ; received_at : 'env -> float
  ; mined_myself : 'env -> bool
  }

type ('env, 'data, 'pow) protocol =
  { dag_roots : 'data list (** Specify the roots of the global DAG. *)
  ; dag_invariant : pow:bool -> 'data list -> 'data -> bool
        (** Restrict the set of valid DAGs. The simulator checks [dag_invariant ~pow
            parents data] for each extension proposed by network nodes via
            {Context.extend_dag}. Extension validity can depend on the proof-of-work
            authorization, parent data, and extension data. *)
  ; honest : ('env, 'data) context -> ('env, 'data, 'pow) node
  }

(** Calculate and assign rewards to a nodes and (potentially) its neighbours. Use this
    together with {!Dag.iterate_ancestors}. *)
type ('env, 'data) reward_function =
  view:'env Dag.view
  -> read:('env -> 'data)
  -> assign:(float -> 'env Dag.node -> unit)
  -> 'env Dag.node
  -> unit
