# Release History

*****************

## Release ONDEWO VTSI C++ Client 9.0.0

### Breaking Changes

* Tracks [ONDEWO VTSI API 9.0.0](https://github.com/ondewo/ondewo-vtsi-api/releases/tag/9.0.0), a major API
  release: binary wire-compatible in both directions, source-breaking. The stubs in `api/` are regenerated from it.
* `AsteriskConfigsFiles.sip_conf_file_string` is renamed to `pjsip_conf_file_string` (field number 1 and type
  `string` unchanged). Migration: rename every generated member of the old field (`sip_conf_file_string()`,
  `set_sip_conf_file_string()`, `mutable_sip_conf_file_string()`, `clear_sip_conf_file_string()`,
  `release_sip_conf_file_string()`, `set_allocated_sip_conf_file_string()`) to the `pjsip_conf_file_string`
  spelling. Bytes written by an 8.7.x client
  parse into the new field. The JSON key moves from `sipConfFileString` to `pjsipConfFileString`, so code that goes
  through `google::protobuf::util::MessageToJsonString` / `JsonStringToMessage` or a hand-written JSON mapping
  must move with it.
* Eleven singular scalars in `ondewo/vtsi/calls.proto` gained `optional` (explicit presence):
  `InterruptionHandlingConfig.transcribe_on_disabled_interruptions`,
  `TurnDetectionConfig.turn_detection_system_prompt` / `turn_detection_user_prompt`,
  `AudioObjectStorageConfig.activate_audio_object_storage`,
  `AudioObjectStorageServicesActivationConfig.activate_s2t` / `activate_t2s`,
  `MessageBrokerConfig.activate_message_broker` and
  `MessageBrokerServicesActivationConfig.activate_s2t` / `activate_nlu` / `activate_t2s` / `activate_sip`.
  Each now generates `has_<field>()`, and an explicitly set default (`false`, `""`) is written to the wire.
  Migration: existing getters and setters keep compiling; use `has_<field>()` where "unset" and "the default"
  must be told apart, and use `clear_<field>()` (not `set_<field>(false)`) to leave a field unset.
* `ondewo-sip-api` inside the VTSI API moves from 5.4.0 to 5.5.0, so the `ondewo::sip` stubs this library carries
  are the 5.5.0 ones, the same as in ondewo-sip-client-cpp 5.5.0.

### New Features

* New services, each with its own generated header pair, included in `public-api.h`:
  * `ondewo.vtsi.Softphones` (`ondewo/vtsi/softphones.proto`): softphone accounts with their own SIP credentials,
    client certificates and provisioning (`CreateSoftphoneAccount`, `GetSoftphoneAccount`,
    `UpdateSoftphoneAccount`, `DeleteSoftphoneAccount`, `ListSoftphoneAccounts`, `RotateSoftphoneCredentials`,
    `ListSoftphoneCertificates`, `GetSoftphoneCertificate`, `RevokeSoftphoneCertificate`,
    `GetSoftphoneProvisioning`). Secrets are returned only by the create and rotate responses.
  * `ondewo.vtsi.Campaigns` (`ondewo/vtsi/campaigns.proto`): outbound call campaigns with bounded parallelism and
    retries - CRUD, `StartCampaign` / `StopCampaign` / `HardStopCampaign` / `ResumeCampaign`,
    `GetCampaignStatistics`, `ListCampaignCalls` and the server stream `StreamCampaignStatus`.
  * `ondewo.vtsi.Events` (`ondewo/vtsi/events.proto`): the `VtsiEvent` catalogue, event subscriptions, webhooks
    (`CreateWebhook` ... `TestWebhook`, custom header values write-only) and the server stream
    `SubscribeVtsiEvents`.
* `Calls` gained `AddCallersToCampaign` / `AddScheduledCallersToCampaign`, the status streams
  `StreamCallerStatus` / `StreamListenerStatus` / `StreamScheduledCallerStatus`, call control (`InviteToCall`,
  `RemoveCallParticipant`, `SetCallMediaControl`), live call audio (`StreamCallAudio`, bidirectional, and
  `ListenCallAudio`, server-streaming) and typed, truthful transfers (`TransferCallRequest.target` / `mode` /
  `headers` / `ring_timeout_s`, `TransferCallResponse.outcome`). `StartCallers`, `StartListeners`,
  `StartScheduledCallers` and the two campaign RPCs take an `idempotency_key`.
* Answering machine detection for pooled persistent callers (`AnsweringMachineDetectionConfig`, `AmdAction`,
  `AmdSensitivity`) and the AMD outcome on `Call` (`redial_recommended`, `redial_reason`,
  `answering_machine_detection_end_description`); `Call` also gained `media_control`, `participants`,
  `last_transfer` and `sip_call_id`.
* `AsteriskConfigsVariables` gained the SIP trunk transport (`sip_trunk_transport`, `sip_trunk_source_cidr`),
  carrier certificate verification (`sip_trunk_ca_certificates_pem`, `sip_trunk_verify_server`) and
  `softphone_permit_cidrs`; `VtsiProject` gained `transfer_phone_number_allowlist`.
* See the [VTSI API 9.0.0 release notes](https://github.com/ondewo/ondewo-vtsi-api/releases/tag/9.0.0) for the
  server behaviour, the rolling-update notes and the full field list.

### Improvements

* The test suite covers the new surface: `tests/product_config.cc` expects the three new `.proto` files and
  services and a slice of the new RPCs and records the 9.0.0 counts (1071 messages, 138 enums, 3183 scalar
  fields); `tests/test_typed_api.cc` constructs the `Softphones`, `Campaigns` and `Events` stubs, dispatches one
  unary RPC of each against a dead endpoint, drives the bidirectional `StreamCallAudio`, pins that
  `pjsip_conf_file_string` keeps field number 1 and that `activate_s2t` sends an explicit `false`.
* The pinned `ondewo-proto-compiler` submodule moves from 5.15.2 to 5.15.5 (its fixes concern the Python, Rust and
  Node.js images; the C++ generation is unchanged).
* Tracking API Version [9.0.0](https://github.com/ondewo/ondewo-vtsi-api/releases/tag/9.0.0) ( [Documentation](https://ondewo.github.io/ondewo-vtsi-api/) )

*****************

## Release ONDEWO VTSI C++ Client 8.7.1

### New Features

* TLS / mutual TLS: new header-only channel helper `ondewo/client/channel.h`, installed beside the generated
  headers and on the exported `ondewo::ondewo_vtsi_client` target's include path. `ondewo::client::ClientConfig`
  (`host`, `port`, `grpc_cert`, `grpc_client_cert`, `grpc_client_key`, `use_secure_channel`) takes PEM **content**,
  not file paths. `CreateChannel`, `CreateChannelCredentials`, `ValidateConfig` and `DefaultChannelArguments()`
  report errors as `grpc::Status` `INVALID_ARGUMENT`, never as exceptions.
* An empty `grpc_cert` uses the platform trust store. Half a client identity (certificate without key or key
  without certificate) and a plaintext channel with a client identity are refused before gRPC is called. A
  plaintext channel logs a warning on `std::clog` naming `host:port`. No error message renders a PEM, a key or the
  config; `ToString()` / `operator<<` print the client key as `***REDACTED***`. Bare IPv6 hosts are bracketed;
  CRLF PEMs work.
* Default channel arguments match the ONDEWO Python SDKs: keepalive every 30 s during calls with a 20 s timeout,
  `grpc.http2.max_pings_without_data=2`, reconnect backoff capped at 5 s, 2^31-1 byte send/receive message limit.
  Documented gaps: gRPC 1.51 ignores `grpc.http2.ping_timeout_ms`, and no per-method retry policy is configured.
* README: new section "TLS, mutual TLS and certificates" (modes, loading a PEM from a file, test PKI, security
  notes, troubleshooting).

### Improvements

* `tests/test_tls.cc`: real handshakes against in-process servers with a PKI generated by the openssl CLI at test
  time - TLS, mutual TLS, server rejecting a missing or foreign client certificate, wrong CA, system trust store,
  non-PEM CA (error, not crash), CRLF PEMs, server-name override, `[::1]` - plus the refusal, warning, redaction
  and default-argument cases. `make coverage` now also holds `client/` to 100 % line coverage.
* `tests/test_release_notes.sh` (CTest) pins the release-notes slice, the heading spelling, the `*****` separators
  and non-empty notes for the current version.
* The pinned `ondewo-proto-compiler` submodule moves from 5.15.1 to 5.15.2 (its fixes concern the PHP, Rust and
  JavaScript images and the release automation; the C++ generation is unchanged).
* Tracking API Version [8.7.0](https://github.com/ondewo/ondewo-vtsi-api/releases/tag/8.7.0) ( [Documentation](https://ondewo.github.io/ondewo-vtsi-api/) )

*****************

## Release ONDEWO VTSI C++ Client 8.7.0

### New Features

* Initial release of `ondewo-vtsi-client-cpp`, the C++ gRPC client library for the
  [ONDEWO VTSI API](https://github.com/ondewo/ondewo-vtsi-api) (Virtual Telephony Server Interface). The stubs are generated
  from the `ondewo-vtsi-api` submodule by the `ondewo-cpp-proto-compiler` image of
  [ondewo-proto-compiler](https://github.com/ondewo/ondewo-proto-compiler) 5.15.1, using protoc's
  built-in `--cpp_out` for the messages and `grpc_cpp_plugin` for the service stubs.
* Ships as a consumable CMake package: `find_package(ondewo_vtsi_client CONFIG REQUIRED)` plus
  `target_link_libraries(my_app PRIVATE ondewo::ondewo_vtsi_client)`. The package installs the generated
  headers under `include/ondewo_vtsi_client/`, the static archive
  `lib/libondewo_vtsi_client.a` and `lib/cmake/ondewo_vtsi_client/`, and re-finds `Protobuf` and
  `gRPC` on the consumer's machine through `find_dependency`.
* `public-api.h` is an umbrella header that includes every generated `*.pb.h` and `*.grpc.pb.h`, so a single
  `#include "public-api.h"` gives access to the whole API surface.
* The generated stub sources are committed to the repository. C++ has no package registry, so a git tag is the
  distribution channel: a plain `git clone` or a CMake `FetchContent_Declare` yields a buildable project with
  no Docker and no code generation step.
* `make build` reproduces the whole pipeline - submodule checkout at the pinned tags, compiler image build,
  code generation and a host-native CMake build - and `make test` verifies that every `.proto` produced a
  header and that the installed CMake package is consumable by a downstream project.

*****************
