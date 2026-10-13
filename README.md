# QuicoptClient.jl

[![Docs (stable)](https://img.shields.io/badge/docs-stable-blue.svg)](https://quicopt.github.io/QuicoptClient.jl/stable/)
[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://quicopt.github.io/QuicoptClient.jl/dev/)
[![CI](https://github.com/Quicopt/QuicoptClient.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Quicopt/QuicoptClient.jl/actions/workflows/CI.yml)
[![Version](https://juliahub.com/docs/General/QuicoptClient/stable/version.svg)](https://juliahub.com/ui/Packages/General/QuicoptClient)
[![Julia 1.10+](https://img.shields.io/badge/julia-1.10%2B-9558B2.svg)](https://julialang.org)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

The Julia client for the [**Quicopt**](https://quicopt.com) optimization service.

You describe a decision: what you get to choose, what has to hold, and what you
want as much (or as little) of as possible. Quicopt finds the best choice there is.

Write the model in [JuMP](https://jump.dev) as you always would, call `solve`, and
read the answer back. There is no solver on your machine; the service does the
solving.

## What it does

- **`import_model(::JuMP.Model)`** — turn a JuMP/MOI model into a Quicopt
  `Program`: affine / quadratic / nonlinear objectives and constraints, variable
  bounds (including unbounded) and integrality, `Min`/`Max`.
- **`encode(program)`** — encode that `Program` to the language-neutral bytes the
  service reads (protobuf).
- **`solve(model)`** — do both and solve it on the service: `POST /v1/solve`
  (or, with `async=true`, the `/v1/jobs` submit-and-poll path — use it for the
  first call against a freshly-started server, whose worker warmup can time out a
  sync call). A free API key is minted on first use and cached locally; the result
  is returned as parsed JSON. A non-2xx response raises a `QuicoptError`.
- **`set_distribution` / `expectation` / `cvar` / `prob`** — say that part of the
  model is uncertain, and optimize over what might happen rather than one guess.
- **`permutation` / `item_at` / `slot_of` / `precede!` / `lookup_table`** —
  decide an order, such as a route, and read data at the positions it puts things.
- **`Semicontinuous` / `Semiinteger` / `active` / `block` / `ifelse`** — a
  delivery of none or at least a minimum load, a fee per delivery or once a total
  passes a threshold, and the variables of one subproblem named as a block.
- **`partition` / `part_of` / `size_of`** — split items into groups, such as
  people into teams.

## Deciding under uncertainty

Not every number in a model is known when you have to choose. Give a variable a
distribution instead of a value, and it stops being something the solver picks
and starts being something the world hands you:

```julia
using QuicoptClient, JuMP

m = Model()
@variable(m, 0 <= stock <= 200)          # decision: how much to hold
@variable(m, demand)                     # random: what will be asked for
set_distribution(m, demand, :normal, 100.0, 15.0)
set_scenarios(m, 512; seed = 42)

@objective(m, Min, 3stock + 10 * expectation(max(demand - stock, 0)))
result = solve(m)
```

This is the newsvendor, and its answer is instructive: it is *not* to stock the
average demand. Running out costs more than overstocking, so the optimum sits
above the mean — the kind of asymmetry you get wrong by plugging in a best guess
and solving deterministically.

Every random quantity has to be closed by an aggregator before it reaches the
objective or a constraint: `expectation` for the average, `cvar(loss, 0.95)` when
the bad case matters more than the typical one, and `prob` for a chance
constraint —

```julia
@constraint(m, prob(demand - stock, ≤, 0) >= 0.9)   # meet demand 90% of the time
```

Using `demand` twice refers to the *same* draw, so independent randomness means
separate variables. `set_scenarios` is part of the model, not a solver knob: the
same count and seed always describe the same problem.

## Deciding an order

Some decisions are an arrangement: the order in which a courier visits its stops,
the order of jobs on a machine. Declare one with `permutation`, read it with
`item_at` and `slot_of`, and read data along it from a `lookup_table`:

```julia
using QuicoptClient, JuMP

position = [0, 3, 1, 4, 2]                        # km along the road, stops 1 to 5
m = Model()
dist  = lookup_table(m, :dist, [abs(a - b) for a in position, b in position])
route = permutation(m, :route, 5)                 # 5 stops in 5 visits
precede!(route, 4, 1)                             # stop 4 is visited before stop 1
@objective(m, Min, sum(dist[item_at(k, route), item_at(k + 1, route)] for k in 1:4))

result = solve(m)
result.objective                                  # 4.0
result.structures.route.item_at                   # [4, 2, 5, 3, 1]: the stops in visiting order
```

`item_at(k, route)` is the stop visited `k`-th and `slot_of(i, route)` the visit
at which stop `i` comes; both are chosen by the service. Indexing `dist` with them
reads the distance between the stops it chooses. Driving from one end of the road
to the other covers the 4 km, and starting at the far end is what visits stop 4
before stop 1.

## Minimum loads, fees and blocks

A delivery is often either nothing or at least a minimum load. JuMP's own
`Semiinteger(10, 25)` set says so: 0, or a whole number from 10 to 25
(`Semicontinuous` for any value in the range). `active(x)` is 1 when such a
variable is not 0, which makes a fee per delivery one term, and `ifelse` over a
comparison, inside a JuMP macro, charges a fee once a total passes a threshold.
A `block` names the variables of one subproblem, such as one customer's
deliveries; every solution returned satisfies the constraints over one block's
variables alone.

```julia
using QuicoptClient, JuMP

demand = [40, 30, 20]                             # units, customers 1 to 3
price = [1 3 4; 3 1 3; 4 2 1]                     # per unit, price[warehouse, customer]
opening = [60, 50, 40]                            # fee of warehouses 1 to 3
m = Model()
@variable(m, ship[1:3, 1:3] in Semiinteger(10, 25))   # every delivery: none, or 10 to 25 units
for c in 1:3
    block(m, "customer_$c", ship[:, c])
    @constraint(m, sum(ship[:, c]) >= demand[c])
end
@objective(m, Min, sum(price .* ship) +
                   sum(5active(ship[w, c]) for w in 1:3, c in 1:3) +            # 5 per delivery
                   sum(ifelse(sum(ship[w, :]) >= 1, opening[w], 0) for w in 1:3))  # opening fee

result = solve(m)
result.objective                                  # 300.0: warehouse 2 stays closed
```

`partition(m, :teams, 6, 2)` splits items into groups the same way a
`permutation` orders them, read through `part_of(item, teams)` and
`size_of(part, teams)`; its docstring has a worked example.

## What travels

A `Program` is what a model *is* to Quicopt — variables, expressions and
constraints as data — and its schema is published
(`proto/quicopt/modeler/v1/program.proto`), so the Python and Ruby clients send
the same thing. The Julia code for it is **generated** from that `.proto` via
[ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl) (`src/proto/`, regenerated by
`gen/gen.jl`) — the client implements the contract without forking it.

## Dependencies

All public: `JuMP`, `ProtoBuf`, `HTTP`, `JSON3`. No solver, no service internals.

## Usage

```julia
using QuicoptClient, JuMP

m = Model()
@variable(m, 0 <= x <= 4)
@variable(m, 0 <= y <= 4)
@objective(m, Max, 3x + 2y)
@constraint(m, x + y <= 5)

result = solve(m)                      # POSTs to the service; prints the result banner
@show result.status result.objective result.solution
```

The first call mints a free key, cached at `$XDG_CACHE_HOME/quicopt/free_key`
(`~/.cache/…` by default) and replayed on every later call — including from later
runs, so you keep one key without doing anything. Where the home directory does not
survive the run (CI, containers), set `QUICOPT_KEY_PATH` (or `solve(m; key_path =
"…")`) to durable storage, or every run mints a new key. Target a specific server
with `solve(m; base_url = "…")`, or use a key you already hold with
`solve(m; key = "…")` (used as-is, never cached). Tag a call with
`solve(m; project = "my-project")` to attribute it to a project (per-project
invoicing when one key serves several); that you wrote it in JuMP is recorded
automatically.

The service decides how long a solve may run. `solve(m; time_limit = 30)` sets it
to 30 seconds instead: a solver that proves its answer sooner still stops sooner,
and a search runs for all of it. The service grants at most its maximum (120 s on
the free tier) and reports what it granted in `result.solver_data.time_budget_s`;
a warning says so when that is less than you asked for.

## Tests

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

Self-contained and offline: each fixture is read, encoded, and its bytes locked
against committed goldens (`test/goldens/*.hex`, regenerated by `gen/goldens.jl`),
alongside a request-path test that never touches the network. That the encoded
bytes mean to the service what the model said is proven separately, in a
verification harness that has both sides in the room.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
(c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich.
