# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# ── sending: ship the encoded model to the Quicopt service ───────────────────
#
# `solve(model)` reads + encodes the model and has the service solve it. Two
# paths, same parsed-JSON result:
#   • sync  (default)      — POST /v1/solve; the server waits for the worker (≤60s).
#   • async (`async=true`) — POST /v1/jobs, poll GET /v1/jobs/{id} to completion,
#     then GET …/result. Use it for the first call against a freshly-booted server:
#     the worker JIT-warms (~30–60s) before claiming, which can 504 a cold sync call.
#
# Keyless on first use: the server mints a key (`X-Quicopt-Api-Key` header), cached
# at `~/.cache/quicopt/free_key` and replayed as a Bearer token (the standard
# free-key cache pattern). The HTTP calls sit behind a `transport` seam — `(method, url, headers,
# body) -> (; status, api_key, body)` — so the mint/cache/poll/parse logic is tested
# with no network.

import HTTP
import JSON3

"""
    DEFAULT_BASE_URL

The public Quicopt service endpoint `solve` targets unless a `base_url` is given.
"""
const DEFAULT_BASE_URL = "https://try.quicoptapi.pgi.fz-juelich.de"

"""
    KEY_PATH_ENV

Environment variable overriding where the free key is cached. Point it at durable
storage in an environment whose home directory does not survive the run (CI,
containers), where the default location is wiped between sessions and every run
would otherwise mint a fresh key.
"""
const KEY_PATH_ENV = "QUICOPT_KEY_PATH"

"""
    _default_key_path() -> String

The default location of the cached free-key file,
`\$XDG_CACHE_HOME/quicopt/free_key` (falling back to `~/.cache` when the variable is
unset), unless [`KEY_PATH_ENV`](@ref) overrides the whole path.
"""
function _default_key_path()
    override = get(ENV, KEY_PATH_ENV, "")
    isempty(override) || return expanduser(override)
    joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "quicopt", "free_key")
end

"""
    _read_key(path) -> String

The cached key, or `""` when there is nothing usable to read. A missing or
unreadable cache is not an error — it just means this caller has no key yet and the
next call mints one.
"""
_read_key(path::AbstractString) =
    isfile(path) ? (try String(strip(read(path, String))) catch; "" end) : ""

"""
    _write_key(path, key)

Persist `key` at `path`, atomically and readable only by its owner.

The key is a credential, so the file is `0o600`; the write goes to a temp file in
the same directory and is then `mv`ed into place, so a crash or a concurrent writer
can never leave a truncated key behind for the next run to send. Caching is
best-effort: an unwritable cache (read-only home, a container without `HOME`) warns
rather than throwing, since the solve itself succeeded and failing it over a cache
miss would be worse than re-minting.
"""
function _write_key(path::AbstractString, key::AbstractString)
    try
        mkpath(dirname(path))
        tmp, io = mktemp(dirname(path))
        write(io, key)
        close(io)
        chmod(tmp, 0o600)
        mv(tmp, path; force = true)
    catch e
        @warn "could not cache the Quicopt free key; every run will mint a new key — \
               set $KEY_PATH_ENV to a writable location" path exception = e
    end
end

"""
    QuicoptError(status, reason, message, display)

A non-2xx response from the service. `reason` is the stable machine code (e.g.
`"unsupported_model"`, `"quota_exhausted"`); `display` is the server's
ready-to-print framed message, shown by `showerror` when present.
"""
struct QuicoptError <: Exception
    status::Int
    reason::String
    message::String
    display::String
end
Base.showerror(io::IO, e::QuicoptError) =
    print(io, isempty(e.display) ? "QuicoptError($(e.status), $(e.reason)): $(e.message)" : e.display)

"""
    _http(method, url, headers, body) -> NamedTuple

The default `transport`: a thin wrapper over `HTTP.request` normalised to what
`solve` reads. Returns `(; status, api_key, body)`, where `api_key` is the
`X-Quicopt-Api-Key` response header (empty if absent). HTTP status errors are not
raised (`status_exception = false`); `solve` inspects `status` itself.
"""
function _http(method::Symbol, url::AbstractString, headers, body)
    r = HTTP.request(method, url, headers, body; status_exception = false)
    return (; status = Int(r.status), api_key = HTTP.header(r, "X-Quicopt-Api-Key", ""), body = r.body)
end

"""
    _error(resp) -> QuicoptError

Build a [`QuicoptError`](@ref) from a non-2xx response `resp` by reading its JSON
body's `reason`/`error`/`display` fields (each defaulting to `""` if the body is
missing or unparseable).
"""
function _error(resp)
    body = try JSON3.read(resp.body) catch; nothing end
    field(k) = body === nothing ? "" : String(get(body, k, ""))
    QuicoptError(resp.status, field(:reason), field(:error), field(:display))
end

"""
    _finish(result, silent) -> result

Return the parsed `result`, first printing its `display` banner unless `silent` is
set (or no banner is present).
"""
_finish(result, silent) = (silent || (haskey(result, :display) && println(result.display)); result)

"""
    solve(model::JuMP.Model; kwargs...) -> JSON3.Object

Read `model`, encode it, and solve it on the Quicopt service. Tags the call with
`source_language = "jump"` (the modeling library it was written in) unless
overridden. See the byte method below for the keyword arguments (incl. `project`).
"""
solve(model::JuMP.Model; source_language::AbstractString = "jump", kwargs...) =
    solve(encode(import_model(model)); source_language = source_language, kwargs...)

"""
    _meta_query(source_language, project, time_limit = nothing) -> String

Build the `?source_language=…&project_id=…&time_limit=…` query suffix carrying
the optional per-call tags (each omitted when empty or `nothing`, values
URL-escaped). These ride the query string, not the encoded model — the model is
the mathematics; these are attributes of the request. Returns `""` when all are
absent.
"""
function _meta_query(source_language::AbstractString, project::AbstractString,
                     time_limit::Union{Nothing,Real} = nothing)
    parts = String[]
    isempty(source_language) || push!(parts, "source_language=" * HTTP.URIs.escapeuri(source_language))
    isempty(project)         || push!(parts, "project_id=" * HTTP.URIs.escapeuri(project))
    time_limit === nothing   || push!(parts, "time_limit=" * string(Float64(time_limit)))
    isempty(parts) ? "" : "?" * join(parts, "&")
end

"""
    _check_time_limit(time_limit) -> Union{Nothing,Float64}

A time limit as sent: `nothing`, or a positive, finite number of seconds.

# Throws
- `ArgumentError`: for anything else.
"""
_check_time_limit(::Nothing) = nothing
function _check_time_limit(t)
    t isa Real && !(t isa Bool) && isfinite(t) && t > 0 ||
        throw(ArgumentError("time_limit is a positive, finite number of seconds, got $(repr(t))"))
    return Float64(t)
end

"""
    _warn_if_lowered(result) -> result

Warn when the service ran a solve for less time than its `time_limit`. The
service grants at most its maximum and reports what was asked
(`solver_data.time_limit_s`) beside what was granted
(`solver_data.time_budget_s`).
"""
function _warn_if_lowered(result)
    sd = get(result, :solver_data, nothing)
    sd === nothing && return result
    asked, granted = get(sd, :time_limit_s, nothing), get(sd, :time_budget_s, nothing)
    if asked !== nothing && granted !== nothing && granted < asked
        @warn "the service ran this solve for $(_seconds(granted)) s, not the " *
              "$(_seconds(asked)) s asked for: $(_seconds(granted)) s is the most it grants"
    end
    return result
end

"""
    _seconds(x) -> String

A number of seconds as written to a person: `120`, not `120.0`.
"""
_seconds(x::Real) = isinteger(x) ? string(Int(x)) : string(x)

"""
    _auth(tok) -> Vector{Pair{String,String}}

The `Authorization: Bearer` header for `tok`, or no headers at all when `tok` is
empty — a keyless request, which is what makes the server mint.
"""
_auth(tok::AbstractString) =
    isempty(tok) ? Pair{String,String}[] : ["Authorization" => "Bearer " * tok]

"""
    _submit(transport, url, tok, bytes) -> NamedTuple

POST the encoded model `bytes` to `url`, authenticating with `tok` when it is
non-empty.
"""
_submit(transport, url::AbstractString, tok::AbstractString, bytes) =
    transport(:POST, url, ["Content-Type" => "application/octet-stream"; _auth(tok)], bytes)

"""
    _submit_authenticated(transport, url, bytes, tok, from_cache, key_path) -> (resp, tok)

Submit, retrying **once** keyless if a *cached* key is rejected, and return the
response together with the token that was ultimately accepted.

A cache file can outlive the key it holds (the server was reset, the key was
revoked, the file was copied from another machine), and a stale key would otherwise
401 every call forever. The retry is deliberately narrow: only a key read from disk
is discarded (`from_cache`), never one minted in this run and never a caller-supplied
`key`. A run can therefore mint at most one key beyond the stale one, so the
recovery path can never itself become the mint loop it exists to fix.
"""
function _submit_authenticated(transport, url::AbstractString, bytes, tok::AbstractString,
                               from_cache::Bool, key_path::AbstractString)
    resp = _submit(transport, url, tok, bytes)
    if resp.status == 401 && from_cache
        rm(key_path; force = true)
        return _submit(transport, url, "", bytes), ""
    end
    return resp, tok
end

"""
    _await_job(transport, base_url, job_id, auth, poll, timeout) -> Vector{UInt8}

Poll `job_id` until the worker reports `done`/`failed`, then return the raw body of
its result. Throws [`QuicoptError`](@ref) on a non-2xx poll, or errors once
`timeout` seconds have elapsed.
"""
function _await_job(transport, base_url::AbstractString, job_id::AbstractString,
                    auth, poll::Real, timeout::Real)
    deadline = time() + timeout
    while true
        st = transport(:GET, string(base_url, "/v1/jobs/", job_id), auth, UInt8[])
        st.status >= 400 && throw(_error(st))
        String(JSON3.read(st.body).status) in ("done", "failed") && break
        time() > deadline && error("QuicoptClient: job $job_id did not finish within $(timeout)s")
        sleep(poll)
    end
    res = transport(:GET, string(base_url, "/v1/jobs/", job_id, "/result"), auth, UInt8[])
    res.status >= 400 && throw(_error(res))
    return res.body
end

"""
    solve(bytes; base_url, key, source_language, project, time_limit, key_path, async, poll, timeout, silent, transport) -> JSON3.Object

POST an already-encoded model and return the parsed JSON result (`status`,
`objective`, `feasible`, `solution`, `display`, …). `async=true` submits to
`/v1/jobs` and polls to completion (use it for the first call against a cold
server — the worker warmup can 504 a sync call); otherwise it is one `/v1/solve`.
Pass `key` to authenticate with a specific key you already hold (e.g. a
distributed internal/test key) — it is used as-is and never written to disk.
Otherwise, on the first keyless call the server mints a free key, cached at
`key_path` (`0o600`, see [`KEY_PATH_ENV`](@ref)) and replayed as a Bearer token
thereafter — including by later runs, so one caller keeps one key. A cached key the
server rejects is discarded and re-minted once. `source_language` and
`project` tag the call (which modeling library wrote it; a project label for
per-project invoicing) — sent as query params, not baked into the model.

`time_limit` sets how many seconds the solve may run, in place of the time the
service would choose: a solver that proves its answer sooner stops sooner, and a
search, which cannot prove it is done, may stop sooner too, once it stops finding
better answers. The service grants at most its maximum (120 s on the free tier),
reports both numbers in `result.solver_data` (`time_limit_s`, `time_budget_s`),
and a warning says so when it granted less. With `async=true` the polling
`timeout` then defaults to the time limit plus a minute, if that is longer than
its usual 180 s.

A non-2xx response throws [`QuicoptError`](@ref). `silent=true` suppresses
printing the result banner.
"""
function solve(bytes::AbstractVector{UInt8};
               base_url::AbstractString = DEFAULT_BASE_URL,
               key::AbstractString = "",
               source_language::AbstractString = "",
               project::AbstractString = "",
               time_limit = nothing,
               key_path::AbstractString = _default_key_path(),
               async::Bool = false, poll::Real = 0.5, timeout::Union{Nothing,Real} = nothing,
               silent::Bool = false, transport = _http)
    time_limit = _check_time_limit(time_limit)
    timeout = timeout !== nothing ? timeout :
              time_limit === nothing ? 180.0 : max(180.0, time_limit + 60.0)
    # An explicit `key` is used as-is and never persisted; otherwise fall back to
    # the cached free key (minting one on the first keyless call).
    explicit = !isempty(key)
    tok = explicit ? String(key) : _read_key(key_path)
    from_cache = !explicit && !isempty(tok)

    submit_url = string(base_url, async ? "/v1/jobs" : "/v1/solve",
                        _meta_query(source_language, project, time_limit))
    resp, tok = _submit_authenticated(transport, submit_url, bytes, tok, from_cache, key_path)
    resp.status >= 400 && throw(_error(resp))

    if !explicit && isempty(tok) && !isempty(resp.api_key)  # cache the minted key, then use it below
        _write_key(key_path, resp.api_key)
        tok = String(resp.api_key)
        silent || @info "minted a free Quicopt key (cached at $key_path)"
    end

    async || return _warn_if_lowered(_finish(JSON3.read(resp.body), silent))

    body = _await_job(transport, base_url, String(JSON3.read(resp.body).job_id),
                      _auth(tok), poll, timeout)
    return _warn_if_lowered(_finish(JSON3.read(body), silent))
end
