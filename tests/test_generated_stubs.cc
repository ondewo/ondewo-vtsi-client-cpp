// Product-agnostic assertions over the committed stubs.
//
// Nothing here names a concrete C++ type - every expectation is read from
// product_config.cc and checked through the descriptor pool, so this file is copied
// unchanged into the other ONDEWO C++ clients.

#include <algorithm>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <google/protobuf/descriptor.h>
#include <google/protobuf/util/message_differencer.h>
#include <gtest/gtest.h>

#include "descriptor_probe.h"
#include "product_config.h"

namespace ondewo_client_test {
namespace {

TEST(GeneratedStubs, EveryProtoFileIsLinkedIntoTheArchive) {
  ASSERT_FALSE(kProtoFileNames.empty()) << "product_config.cc lists no .proto files";
  for (const std::string& file_name : kProtoFileNames) {
    // A failure here means the .proto was not generated into api/, or its object never
    // made it into the archive. Keep the message on one line: GoogleTest only evaluates a
    // streamed message when the expectation fails, and a continuation line would then show
    // up in the coverage report as unreachable.
    EXPECT_NE(FindFile(file_name), nullptr) << file_name << " is not in the descriptor pool";
  }
}

TEST(GeneratedStubs, EveryServiceIsRegisteredAndHasMethods) {
  ASSERT_FALSE(kServiceFullNames.empty()) << "product_config.cc lists no services";
  for (const std::string& service_full_name : kServiceFullNames) {
    const google::protobuf::ServiceDescriptor* service = FindService(service_full_name);
    ASSERT_NE(service, nullptr) << service_full_name << " is not in the descriptor pool";
    EXPECT_GT(service->method_count(), 0) << service_full_name << " declares no RPC";
  }
}

TEST(GeneratedStubs, EveryExpectedMethodExists) {
  ASSERT_FALSE(kExpectedMethods.empty()) << "product_config.cc lists no expected methods";
  for (const ExpectedMethod& expected : kExpectedMethods) {
    const std::vector<std::string> methods = MethodNames(expected.service_full_name);
    EXPECT_NE(std::find(methods.begin(), methods.end(), expected.method_name), methods.end())
        << expected.service_full_name << " has no RPC named " << expected.method_name;
  }
}

// The negative half of every lookup: a name the stubs do not declare must come back as
// "absent", never as a stale or fabricated descriptor.
TEST(GeneratedStubs, UnknownNamesResolveToNothing) {
  EXPECT_EQ(FindFile("ondewo/nowhere/missing.proto"), nullptr);
  EXPECT_EQ(FindMessage("ondewo.nowhere.MissingMessage"), nullptr);
  EXPECT_EQ(FindService("ondewo.nowhere.MissingService"), nullptr);
  EXPECT_TRUE(MethodNames("ondewo.nowhere.MissingService").empty());
  EXPECT_TRUE(MessagesInFile("ondewo/nowhere/missing.proto").empty());
  EXPECT_TRUE(EnumsInFile("ondewo/nowhere/missing.proto").empty());
  EXPECT_EQ(NewMessage("ondewo.nowhere.MissingMessage"), nullptr);
}

// The broadest generator check in the suite: instantiate EVERY generated message, put a
// value into every singular scalar field it declares, push it through the wire format and
// read it back. A writer that skips a field, a reader that ignores one, or a field number
// that disagrees between the two shows up here as an inequality.
TEST(GeneratedStubs, EveryMessageRoundTripsThroughTheWireFormat) {
  int messages_checked = 0;
  int fields_filled = 0;
  for (const std::string& file_name : kProtoFileNames) {
    for (const google::protobuf::Descriptor* descriptor : MessagesInFile(file_name)) {
      std::unique_ptr<google::protobuf::Message> message = NewMessage(descriptor->full_name());
      ASSERT_NE(message, nullptr) << descriptor->full_name() << " has no generated C++ class";
      fields_filled += FillScalarFields(message.get());
      EXPECT_TRUE(RoundTrips(*message))
          << descriptor->full_name() << " does not survive serialize -> parse";
      ++messages_checked;
    }
  }
  std::cout << "[          ] swept " << messages_checked << " messages, filled "
            << fields_filled << " scalar fields" << std::endl;
  // Floors, not exact counts: the API gains messages and fields over time, but it must
  // never silently lose most of them because a .proto stopped being generated or linked.
  EXPECT_GE(messages_checked, kMinimumMessageCount) << "the sweep checked far too few messages";
  EXPECT_GE(fields_filled, kMinimumScalarFieldCount) << "the sweep set far too few fields";
}

// FillScalarFields branches on the protobuf C++ type, and no single product uses every one
// of them - the sip protos, for instance, declare no float and no uint64 at all. The
// branches are therefore pinned down here against google.protobuf's wrapper types, which
// libprotobuf registers into this same generated pool and which carry exactly one field of
// each scalar type. This is what keeps the helper honest for every ONDEWO product without
// having to trim it per repository.
TEST(GeneratedStubs, FillScalarFieldsHandlesEveryProtobufScalarType) {
  const std::vector<std::string> one_field_wrappers = {
      "google.protobuf.DoubleValue", "google.protobuf.FloatValue",
      "google.protobuf.Int64Value",  "google.protobuf.UInt64Value",
      "google.protobuf.Int32Value",  "google.protobuf.UInt32Value",
      "google.protobuf.BoolValue",   "google.protobuf.StringValue",
      "google.protobuf.BytesValue",
  };
  for (const std::string& full_name : one_field_wrappers) {
    std::unique_ptr<google::protobuf::Message> message = NewMessage(full_name);
    ASSERT_NE(message, nullptr) << full_name << " is not in the generated pool";
    EXPECT_EQ(FillScalarFields(message.get()), 1) << full_name << " was left unset";
    EXPECT_FALSE(message->SerializeAsString().empty()) << full_name << " never reached the wire";
    EXPECT_TRUE(RoundTrips(*message)) << full_name << " does not survive serialize -> parse";
  }

  // google.protobuf.Value is a oneof of an enum, a double, a string, a bool and two
  // message-typed alternatives - the last of which is the branch that must stay untouched.
  std::unique_ptr<google::protobuf::Message> value = NewMessage("google.protobuf.Value");
  ASSERT_NE(value, nullptr);
  EXPECT_EQ(FillScalarFields(value.get()), 4) << "google.protobuf.Value: unexpected fill count";
  EXPECT_TRUE(RoundTrips(*value));

  // A message whose only field is message-typed must come back untouched.
  std::unique_ptr<google::protobuf::Message> wrapper = NewMessage("google.protobuf.Struct");
  ASSERT_NE(wrapper, nullptr);
  EXPECT_EQ(FillScalarFields(wrapper.get()), 0) << "a map<> field was filled after all";
  EXPECT_TRUE(wrapper->SerializeAsString().empty());
}

// proto3 requires the first value of an enum to be 0, and the generated code has to carry
// that value: an enum whose zero value went missing makes the "unspecified" case of every
// request using it unrepresentable.
TEST(GeneratedStubs, EveryEnumDeclaresZeroAsItsFirstValue) {
  int enums_checked = 0;
  for (const std::string& file_name : kProtoFileNames) {
    for (const google::protobuf::EnumDescriptor* enum_type : EnumsInFile(file_name)) {
      ASSERT_GT(enum_type->value_count(), 0) << enum_type->full_name() << " declares no value";
      EXPECT_EQ(enum_type->value(0)->number(), 0)
          << enum_type->full_name() << " does not start at 0";
      EXPECT_NE(enum_type->FindValueByNumber(0), nullptr)
          << enum_type->full_name() << " has no value numbered 0";
      ++enums_checked;
    }
  }
  std::cout << "[          ] swept " << enums_checked << " enums" << std::endl;
  EXPECT_GE(enums_checked, kMinimumEnumCount) << "the sweep checked far too few enums";
}

TEST(GeneratedStubs, ConfiguredEnumIsPresentAndStartsAtZero) {
  const google::protobuf::EnumDescriptor* enum_type =
      google::protobuf::DescriptorPool::generated_pool()->FindEnumTypeByName(kEnumFullName);
  ASSERT_NE(enum_type, nullptr) << kEnumFullName << " is not in the descriptor pool";
  ASSERT_GT(enum_type->value_count(), 1) << kEnumFullName << " lost its values";
  EXPECT_EQ(enum_type->value(0)->number(), 0);
}

// A message that is known to carry scalars has to put bytes on the wire - this is the
// check that would fail if FillScalarFields silently stopped setting anything.
TEST(GeneratedStubs, ConfiguredScalarMessageReachesTheWire) {
  std::unique_ptr<google::protobuf::Message> message = NewMessage(kScalarMessageFullName);
  ASSERT_NE(message, nullptr) << kScalarMessageFullName << " is not in the descriptor pool";
  EXPECT_GT(FillScalarFields(message.get()), 0)
      << kScalarMessageFullName << " has no singular scalar field left";

  std::string bytes;
  ASSERT_TRUE(message->SerializeToString(&bytes));
  EXPECT_FALSE(bytes.empty()) << "a fully populated " << kScalarMessageFullName
                              << " serialised to zero bytes";
  EXPECT_TRUE(RoundTrips(*message));
}

// The comparison RoundTrips is built on has to be able to say "no" - otherwise the sweep
// above would pass even against a generator that writes nothing at all.
TEST(GeneratedStubs, RoundTripComparisonDetectsADifferentPayload) {
  std::unique_ptr<google::protobuf::Message> message = NewMessage(kScalarMessageFullName);
  ASSERT_NE(message, nullptr);
  FillScalarFields(message.get());

  std::unique_ptr<google::protobuf::Message> other(message->New());
  EXPECT_FALSE(google::protobuf::util::MessageDifferencer::Equals(*message, *other))
      << "a populated message compares equal to an empty one";
}

}  // namespace
}  // namespace ondewo_client_test
