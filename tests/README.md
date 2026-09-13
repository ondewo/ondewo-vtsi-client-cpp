# Test suite

GoogleTest/CTest suite over the **committed** stubs in `api/`. It needs no Docker, no proto
compiler and neither submodule — it builds and exercises the code that is in this repository.

```bash
make build_library   # compile + install the client package into the repo root
make unit_test       # build and run the suite
make coverage        # same, under gcov, failing below COVERAGE_MIN % line coverage
make test            # check_stubs -> check_build -> unit_test -> smoke_test
```

## Layout

| File | Product-specific? | What it is |
| --- | --- | --- |
| `product_config.{h,cc}` | **yes** | The expectation tables: proto files, services, a slice of the RPC surface, the sweep floors |
| `descriptor_probe.{h,cc}` | no | Reflection helpers over the generated descriptor pool |
| `test_generated_stubs.cc` | no | Pool-wide assertions driven entirely by `product_config.cc` |
| `test_typed_api.cc` | **yes** | Assertions against concrete `ondewo::vtsi` / `ondewo::sip` / `ondewo::qa` C++ types |
| `CMakeLists.txt` | no | Standalone project consuming the installed CMake package |

The three product-agnostic files are byte-identical to the ones in `ondewo-nlu-client-cpp`;
replicating the suite to another ONDEWO C++ client means rewriting only the two marked **yes**.

## What it actually checks

VTSI is a composition product, and the suite asserts the whole composed surface: all
**29** `.proto` files (its own `ondewo/vtsi/{calls,logs,projects}.proto` plus the NLU, QA, S2T,
SIP and T2S trees it imports) and all **23** services must be in the descriptor pool.

- Every `.proto` listed in `product_config.cc` is registered, every service exists and declares
  RPCs, and a representative slice of method names is present — the full `VtsiProject` CRUD
  surface, the caller/listener/call RPCs the product exists for, `StreamCallLogs`, and one RPC
  from each of the `ondewo.sip`, `ondewo.qa`, `ondewo.s2t`, `ondewo.t2s` and `ondewo.nlu`
  packages the same archive carries.
- **Every** generated message is instantiated, has each of its singular scalar fields set to a
  non-default value, and is pushed through `SerializeToString` → `ParseFromString` → compare:
  **964** messages and **2816** singular scalar fields at ONDEWO VTSI API 8.7.0. A writer that
  drops a field, a reader that ignores one, or a field-number mismatch between the two fails here.
- All **108** generated enums declare `0` as their first value, as proto3 requires — including
  `CallView`, whose zero value `MINIMUM` is the one the Angular presence bug made unrequestable.
- `FillScalarFields` handles every protobuf scalar type. No single product uses all of them, so
  the branches are pinned against `google.protobuf`'s wrapper types, which libprotobuf registers
  into the same pool. That is what lets `descriptor_probe.cc` be copied between products untouched.
- `optional string asterisk_version` of `ondewo::vtsi::AsteriskConfigs` — a proto3 *explicit
  presence* field — still reports `has_asterisk_version()` after an empty-string round trip,
  while the plain `asterisk_port` correctly keeps its zero value off the wire. The VTSI API
  relies on exactly that distinction: unset means "keep the server default", empty is rejected.
- Service stubs are constructed against a channel, and a unary RPC (`GetVtsiProject`) and a
  **server**-streaming RPC (`StreamCallLogs`, a `ClientReader` — VTSI declares no bidirectional
  RPC of its own) are actually issued against a dead endpoint: each must come back as
  `UNAVAILABLE` / `DEADLINE_EXCEEDED`, which proves the stubs, the request/response types and
  the generated method descriptors all link and dispatch.

## Notes on the build

- The suite is a **standalone** CMake project and is not `add_subdirectory()`-ed from the root
  `CMakeLists.txt`: that file is shipped verbatim by the compiler image and is overwritten on
  every regeneration. Consuming the installed package instead is also the stronger test.
- It links the client archive with `--whole-archive` (`-force_load` on macOS). A static archive
  otherwise contributes only the objects needed to resolve a referenced symbol, and the
  descriptor registration of a generated `*.pb.o` is a static initialiser nothing references —
  without it the pool-wide sweeps would silently check only the handful of files
  `test_typed_api.cc` names.
- It compiles with `-fno-exceptions`. Nothing here throws, and the compiler-generated unwind
  blocks otherwise land on every closing brace as lines no test can reach.

## Coverage

`make coverage` measures **hand-written** code only: the gcovr filter is `tests/`, and the
client archive is compiled without `--coverage`, so no generated `*.pb.cc` can contribute a
line either way. The floor is 100 % lines (`COVERAGE_MIN`) and CI enforces it — measured
**100 % of 303 lines and 67 of 67 functions**. The generated stubs are excluded from the
*metric* but are the *subject* of every test above.
