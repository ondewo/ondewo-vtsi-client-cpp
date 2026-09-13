#include "product_config.h"

namespace ondewo_client_test {

// Mirrors the #include list of the generated public-api.h, one .proto per pair of headers:
//   sed -n 's|^#include "\(.*\)\.pb\.h"$|\1|p' public-api.h | sed 's|\.grpc$||' | sort -u
//
// VTSI is a composition product: ondewo/vtsi/{calls,logs,projects}.proto are the three .proto
// files the VTSI API declares itself, and they pull the NLU, QA, S2T, SIP and T2S surfaces in
// as imports - a call started through VTSI is configured with all of them, so all of them are
// generated and linked.
const std::vector<std::string> kProtoFileNames = {
    "google/api/annotations.proto",
    "google/api/http.proto",
    "google/rpc/status.proto",
    "google/type/latlng.proto",
    "ondewo/nlu/agent.proto",
    "ondewo/nlu/aiservices.proto",
    "ondewo/nlu/ccai_project.proto",
    "ondewo/nlu/common.proto",
    "ondewo/nlu/context.proto",
    "ondewo/nlu/entity_type.proto",
    "ondewo/nlu/intent.proto",
    "ondewo/nlu/llm_evaluation.proto",
    "ondewo/nlu/operation_metadata.proto",
    "ondewo/nlu/operations.proto",
    "ondewo/nlu/project_role.proto",
    "ondewo/nlu/project_statistics.proto",
    "ondewo/nlu/rag.proto",
    "ondewo/nlu/server_statistics.proto",
    "ondewo/nlu/session.proto",
    "ondewo/nlu/user.proto",
    "ondewo/nlu/utility.proto",
    "ondewo/nlu/webhook.proto",
    "ondewo/qa/qa.proto",
    "ondewo/s2t/speech-to-text.proto",
    "ondewo/sip/sip.proto",
    "ondewo/t2s/text-to-speech.proto",
    "ondewo/vtsi/calls.proto",
    "ondewo/vtsi/logs.proto",
    "ondewo/vtsi/projects.proto",
};

// The product's own three services plus the 16 NLU services and the QA / S2T / SIP / T2S
// services it re-exports. There is no ondewo.csi.Conversations here - VTSI talks to the CSI
// server over its own Call configuration rather than importing ondewo/csi/conversation.proto.
const std::vector<std::string> kServiceFullNames = {
    "ondewo.nlu.Agents",
    "ondewo.nlu.AiServices",
    "ondewo.nlu.CcaiProjects",
    "ondewo.nlu.Contexts",
    "ondewo.nlu.EntityTypes",
    "ondewo.nlu.Intents",
    "ondewo.nlu.LlmEvaluations",
    "ondewo.nlu.Operations",
    "ondewo.nlu.ProjectRoles",
    "ondewo.nlu.ProjectStatistics",
    "ondewo.nlu.Rags",
    "ondewo.nlu.ServerStatistics",
    "ondewo.nlu.Sessions",
    "ondewo.nlu.Users",
    "ondewo.nlu.Utilities",
    "ondewo.nlu.Webhook",
    "ondewo.qa.QA",
    "ondewo.s2t.Speech2Text",
    "ondewo.sip.Sip",
    "ondewo.t2s.Text2Speech",
    "ondewo.vtsi.Calls",
    "ondewo.vtsi.Logs",
    "ondewo.vtsi.Projects",
};

const std::vector<ExpectedMethod> kExpectedMethods = {
    // The complete CRUD surface of one of the product's own services ...
    {"ondewo.vtsi.Projects", "CreateVtsiProject"},
    {"ondewo.vtsi.Projects", "GetVtsiProject"},
    {"ondewo.vtsi.Projects", "UpdateVtsiProject"},
    {"ondewo.vtsi.Projects", "DeleteVtsiProject"},
    {"ondewo.vtsi.Projects", "ListVtsiProjects"},
    // ... the RPCs the product exists for ...
    {"ondewo.vtsi.Calls", "StartCaller"},
    {"ondewo.vtsi.Calls", "StartListener"},
    {"ondewo.vtsi.Calls", "StopCall"},
    {"ondewo.vtsi.Calls", "GetCall"},
    {"ondewo.vtsi.Calls", "ListCalls"},
    // ... a server-streaming RPC ...
    {"ondewo.vtsi.Logs", "StreamCallLogs"},
    {"ondewo.vtsi.Logs", "ListCallLogs"},
    // ... and one RPC from each of the other proto packages the same library carries, so a
    // .proto that silently stops being generated cannot go unnoticed.
    {"ondewo.sip.Sip", "SipStartCall"},
    {"ondewo.qa.QA", "GetAnswer"},
    {"ondewo.s2t.Speech2Text", "TranscribeStream"},
    {"ondewo.t2s.Text2Speech", "Synthesize"},
    {"ondewo.nlu.Sessions", "DetectIntent"},
};

const std::string kScalarMessageFullName = "ondewo.vtsi.VtsiProject";

const std::string kEnumFullName = "ondewo.vtsi.CallView";

// ONDEWO VTSI API 8.7.0 generates 964 messages (map entries excluded), 108 enums and 2816
// singular scalar fields across the files listed above. The floors sit just below that.
const int kMinimumMessageCount = 950;
const int kMinimumEnumCount = 105;
const int kMinimumScalarFieldCount = 2770;

}  // namespace ondewo_client_test
