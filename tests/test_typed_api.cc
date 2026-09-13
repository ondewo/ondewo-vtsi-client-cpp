// Assertions against the concrete C++ types the VTSI stubs generate.
//
// This is the per-product half of the suite: it names ondewo::vtsi types (and the ondewo::sip /
// ondewo::qa types the VTSI library carries with them), so replicating the suite to another
// ONDEWO client means rewriting this file against that product's messages and services.
// Everything generic lives in test_generated_stubs.cc.

#include <chrono>
#include <memory>
#include <string>

#include <grpcpp/grpcpp.h>
#include <gtest/gtest.h>

#include "ondewo/nlu/session.grpc.pb.h"
#include "ondewo/qa/qa.grpc.pb.h"
#include "ondewo/sip/sip.grpc.pb.h"
#include "ondewo/vtsi/calls.grpc.pb.h"
#include "ondewo/vtsi/calls.pb.h"
#include "ondewo/vtsi/logs.grpc.pb.h"
#include "ondewo/vtsi/logs.pb.h"
#include "ondewo/vtsi/projects.grpc.pb.h"
#include "ondewo/vtsi/projects.pb.h"

namespace ondewo_client_test {
namespace {

// A channel to a port nothing listens on. gRPC connects lazily, so constructing stubs
// against it touches no network at all; the one test that does issue an RPC gives it a
// short deadline and asserts only that the call comes back as a failure.
std::shared_ptr<grpc::Channel> DeadChannel() {
  return grpc::CreateChannel("127.0.0.1:1", grpc::InsecureChannelCredentials());
}

TEST(TypedApi, MessageSurvivesSerializeAndParse) {
  ondewo::vtsi::VtsiProject original;
  original.set_name("projects/9c1f-project/project");
  original.set_display_name("My VTSI project");
  original.set_max_callers(12);
  original.set_max_listeners(4);
  original.set_vtsi_project_status(ondewo::vtsi::VtsiProjectStatus::DEPLOYED);
  original.set_asterisk_port(5060);
  original.add_nlu_agent_names("projects/an-agent/agent");
  original.mutable_asterisk_configs()->set_asterisk_configs_target_directory_name("default");

  std::string bytes;
  ASSERT_TRUE(original.SerializeToString(&bytes));
  EXPECT_FALSE(bytes.empty());

  ondewo::vtsi::VtsiProject parsed;
  ASSERT_TRUE(parsed.ParseFromString(bytes));

  EXPECT_EQ(parsed.name(), "projects/9c1f-project/project");
  EXPECT_EQ(parsed.display_name(), "My VTSI project");
  EXPECT_EQ(parsed.max_callers(), 12);
  EXPECT_EQ(parsed.max_listeners(), 4);
  EXPECT_EQ(parsed.vtsi_project_status(), ondewo::vtsi::VtsiProjectStatus::DEPLOYED);
  EXPECT_EQ(parsed.asterisk_port(), 5060);
  ASSERT_EQ(parsed.nlu_agent_names_size(), 1);
  EXPECT_EQ(parsed.nlu_agent_names(0), "projects/an-agent/agent");
  EXPECT_EQ(parsed.asterisk_configs().asterisk_configs_target_directory_name(), "default");
  EXPECT_EQ(parsed.SerializeAsString(), bytes);
}

// `optional string asterisk_version = 5` has proto3 explicit presence. Set to "" - the type's
// default - it must still reach the wire and still read back as *present*; a generator that
// drops the presence bit makes "" unsendable, which is exactly the class of bug that hit the
// Angular client. The VTSI API relies on the distinction: an unset asterisk_version means
// "keep the server default" while an empty one is explicitly rejected.
TEST(TypedApi, ExplicitPresenceFieldSurvivesItsZeroValue) {
  ondewo::vtsi::AsteriskConfigs original;
  EXPECT_FALSE(original.has_asterisk_version());

  original.set_asterisk_version("");
  ASSERT_TRUE(original.has_asterisk_version());

  const std::string bytes = original.SerializeAsString();
  EXPECT_FALSE(bytes.empty()) << "an explicitly present \"\" was not written to the wire";

  ondewo::vtsi::AsteriskConfigs parsed;
  ASSERT_TRUE(parsed.ParseFromString(bytes));
  EXPECT_TRUE(parsed.has_asterisk_version()) << "presence of an empty value was lost";
  EXPECT_EQ(parsed.asterisk_version(), "");

  original.clear_asterisk_version();
  EXPECT_FALSE(original.has_asterisk_version());
  EXPECT_TRUE(original.SerializeAsString().empty());
}

// A plain (non-optional) proto3 scalar has the opposite contract: its zero value is the
// default and must NOT be written. Asserting both directions is what proves the two field
// kinds really are generated differently.
TEST(TypedApi, PlainScalarZeroValueStaysOffTheWire) {
  ondewo::vtsi::AsteriskConfigs configs;
  configs.set_asterisk_port(0);
  EXPECT_TRUE(configs.SerializeAsString().empty());

  configs.set_asterisk_port(5060);
  EXPECT_FALSE(configs.SerializeAsString().empty());
}

TEST(TypedApi, EnumZeroValueIsTheUnspecifiedOne) {
  EXPECT_EQ(static_cast<int>(ondewo::vtsi::CallView::MINIMUM), 0);
  EXPECT_EQ(ondewo::vtsi::CallView_Name(ondewo::vtsi::CallView::MINIMUM), "MINIMUM");
  EXPECT_EQ(static_cast<int>(ondewo::vtsi::CallStatus::CALL_STATUS_UNSPECIFIED), 0);
  EXPECT_EQ(static_cast<int>(ondewo::vtsi::VtsiProjectStatus::UNSPECIFIED), 0);

  ondewo::vtsi::CallView parsed = ondewo::vtsi::CallView::FULL;
  ASSERT_TRUE(ondewo::vtsi::CallView_Parse("MINIMUM", &parsed));
  EXPECT_EQ(parsed, ondewo::vtsi::CallView::MINIMUM);

  // A request defaults to the zero view, so the zero value has to be requestable.
  ondewo::vtsi::GetVtsiProjectRequest request;
  EXPECT_EQ(request.vtsi_project_view(),
            ondewo::vtsi::VtsiProjectView::VTSI_PROJECT_VIEW_UNSPECIFIED);
}

TEST(TypedApi, ServiceStubsAreConstructibleAgainstAChannel) {
  const std::shared_ptr<grpc::Channel> channel = DeadChannel();
  ASSERT_NE(channel, nullptr);

  std::unique_ptr<ondewo::vtsi::Projects::Stub> projects =
      ondewo::vtsi::Projects::NewStub(channel);
  std::unique_ptr<ondewo::vtsi::Calls::Stub> calls = ondewo::vtsi::Calls::NewStub(channel);
  std::unique_ptr<ondewo::vtsi::Logs::Stub> logs = ondewo::vtsi::Logs::NewStub(channel);
  std::unique_ptr<ondewo::sip::Sip::Stub> sip = ondewo::sip::Sip::NewStub(channel);
  std::unique_ptr<ondewo::qa::QA::Stub> qa = ondewo::qa::QA::NewStub(channel);
  std::unique_ptr<ondewo::nlu::Sessions::Stub> sessions =
      ondewo::nlu::Sessions::NewStub(channel);

  EXPECT_NE(projects, nullptr);
  EXPECT_NE(calls, nullptr);
  EXPECT_NE(logs, nullptr);
  EXPECT_NE(sip, nullptr);
  EXPECT_NE(qa, nullptr);
  EXPECT_NE(sessions, nullptr);
}

TEST(TypedApi, ServicesKeepTheirFullyQualifiedNames) {
  EXPECT_STREQ(ondewo::vtsi::Projects::service_full_name(), "ondewo.vtsi.Projects");
  EXPECT_STREQ(ondewo::vtsi::Calls::service_full_name(), "ondewo.vtsi.Calls");
  EXPECT_STREQ(ondewo::vtsi::Logs::service_full_name(), "ondewo.vtsi.Logs");
  EXPECT_STREQ(ondewo::sip::Sip::service_full_name(), "ondewo.sip.Sip");
  EXPECT_STREQ(ondewo::qa::QA::service_full_name(), "ondewo.qa.QA");
}

// Actually issue an RPC. Nothing is listening, so the only correct outcome is a failure -
// but reaching a transport-level failure means the stub, the request/response types and
// the generated method descriptor all linked and dispatched. A crash or an OK here would
// mean the generated client is broken.
TEST(TypedApi, UnaryRpcAgainstADeadEndpointFailsCleanly) {
  std::unique_ptr<ondewo::vtsi::Projects::Stub> projects =
      ondewo::vtsi::Projects::NewStub(DeadChannel());

  grpc::ClientContext client_context;
  client_context.set_deadline(std::chrono::system_clock::now() + std::chrono::seconds(5));

  ondewo::vtsi::GetVtsiProjectRequest request;
  request.set_name("projects/9c1f-project/project");
  ondewo::vtsi::VtsiProject response;

  const grpc::Status status =
      projects->GetVtsiProject(&client_context, request, &response);

  EXPECT_FALSE(status.ok()) << "an RPC to a dead endpoint reported success";
  EXPECT_TRUE(status.error_code() == grpc::StatusCode::UNAVAILABLE ||
              status.error_code() == grpc::StatusCode::DEADLINE_EXCEEDED)
      << "unexpected status " << status.error_code() << ": " << status.error_message();
}

// StreamCallLogs is SERVER-streaming - VTSI declares no bidirectional RPC of its own - so it
// gets a generated ClientReader, with the request passed by value at construction and no
// WritesDone. Driving one proves that half of the generated service compiled and dispatches.
TEST(TypedApi, ServerStreamingRpcStubIsUsable) {
  std::unique_ptr<ondewo::vtsi::Logs::Stub> logs = ondewo::vtsi::Logs::NewStub(DeadChannel());

  grpc::ClientContext client_context;
  client_context.set_deadline(std::chrono::system_clock::now() + std::chrono::seconds(5));

  ondewo::vtsi::StreamCallLogsRequest request;
  request.set_vtsi_project_name("projects/9c1f-project/project");
  request.set_tail_lines(100);
  ASSERT_TRUE(request.has_tail_lines());

  std::unique_ptr<grpc::ClientReader<ondewo::vtsi::StreamCallLogsResponse>> stream(
      logs->StreamCallLogs(&client_context, request));
  ASSERT_NE(stream, nullptr);

  ondewo::vtsi::StreamCallLogsResponse response;
  EXPECT_FALSE(stream->Read(&response)) << "a dead endpoint returned a streamed response";

  const grpc::Status status = stream->Finish();
  EXPECT_FALSE(status.ok()) << "a stream to a dead endpoint reported success";
}

}  // namespace
}  // namespace ondewo_client_test
