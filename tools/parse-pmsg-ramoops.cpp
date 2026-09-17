#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr size_t kPmsgHeaderSize = 19;
constexpr uint16_t kMaxPayload = 4068;
constexpr uint8_t kFirstLogId = 0;
constexpr uint8_t kLastLogId = 7;
constexpr uint8_t kFirstPriority = 2;
constexpr uint8_t kLastPriority = 7;
constexpr uint32_t kNanosecondsPerSecond = 1000000000U;

struct Options {
  std::string input_path;
  std::string contains;
};

uint16_t ReadLe16(const uint8_t* bytes) {
  return static_cast<uint16_t>(bytes[0]) |
         (static_cast<uint16_t>(bytes[1]) << 8);
}

uint32_t ReadLe32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

std::string Lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::string Escape(const uint8_t* bytes, size_t length) {
  std::ostringstream output;
  for (size_t index = 0; index < length; ++index) {
    const unsigned char byte = bytes[index];
    if (byte == '\n') {
      output << "\\n";
    } else if (byte == '\r') {
      output << "\\r";
    } else if (byte == '\t') {
      output << "\\t";
    } else if (std::isprint(byte)) {
      output << static_cast<char>(byte);
    } else {
      output << "\\x" << std::hex << std::setw(2) << std::setfill('0')
             << static_cast<unsigned int>(byte) << std::dec << std::setfill(' ');
    }
  }
  return output.str();
}

std::string FormatTimestamp(uint32_t seconds, uint32_t nanoseconds) {
  const std::time_t epoch = static_cast<std::time_t>(seconds);
  std::tm utc{};
#ifdef _WIN32
  gmtime_s(&utc, &epoch);
#else
  gmtime_r(&epoch, &utc);
#endif
  std::ostringstream output;
  output << std::put_time(&utc, "%Y-%m-%dT%H:%M:%S") << '.'
         << std::setw(9) << std::setfill('0') << nanoseconds << 'Z';
  return output.str();
}

bool ParseOptions(int argc, char* argv[], Options* options) {
  if (argc < 2) {
    return false;
  }

  options->input_path = argv[1];
  for (int index = 2; index < argc; ++index) {
    const std::string argument = argv[index];
    if (argument == "--contains" && index + 1 < argc) {
      options->contains = Lower(argv[++index]);
      continue;
    }
    return false;
  }
  return true;
}

void PrintUsage(const char* executable) {
  std::cerr << "usage: " << executable
            << " <pmsg-ramoops-0.txt> [--contains <case-insensitive-text>]\n";
}

}  // namespace

int main(int argc, char* argv[]) {
  Options options;
  if (!ParseOptions(argc, argv, &options)) {
    PrintUsage(argv[0]);
    return 2;
  }

  std::ifstream input(options.input_path, std::ios::binary);
  if (!input) {
    std::cerr << "error: cannot open " << options.input_path << '\n';
    return 1;
  }

  const std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)),
                                   std::istreambuf_iterator<char>());
  size_t offset = 0;
  size_t records = 0;
  size_t skipped = 0;

  while (offset + kPmsgHeaderSize <= bytes.size()) {
    const uint8_t* record = bytes.data() + offset;
    if (record[0] != static_cast<uint8_t>('l')) {
      ++offset;
      ++skipped;
      continue;
    }

    const uint16_t length = ReadLe16(record + 1);
    const uint16_t uid = ReadLe16(record + 3);
    const uint16_t pid = ReadLe16(record + 5);
    const uint8_t log_id = record[7];
    const uint16_t tid = ReadLe16(record + 8);
    const uint32_t seconds = ReadLe32(record + 10);
    const uint32_t nanoseconds = ReadLe32(record + 14);
    const uint8_t priority = record[18];

    const bool valid = length > kPmsgHeaderSize &&
                       length <= kPmsgHeaderSize + kMaxPayload &&
                       offset + length <= bytes.size() &&
                       log_id >= kFirstLogId && log_id <= kLastLogId &&
                       nanoseconds < kNanosecondsPerSecond &&
                       priority >= kFirstPriority && priority <= kLastPriority;
    if (!valid) {
      ++offset;
      ++skipped;
      continue;
    }

    const uint8_t* payload = record + kPmsgHeaderSize;
    const size_t payload_length = length - kPmsgHeaderSize;
    size_t tag_length = 0;
    while (tag_length < payload_length && payload[tag_length] != '\0') {
      ++tag_length;
    }

    const bool has_tag = tag_length < payload_length;
    const std::string tag = Escape(payload, tag_length);
    const size_t message_offset = has_tag ? tag_length + 1 : tag_length;
    size_t message_length = payload_length - message_offset;
    while (message_length > 0 && payload[message_offset + message_length - 1] == '\0') {
      --message_length;
    }
    const std::string message = Escape(payload + message_offset, message_length);
    const std::string searchable = Lower(tag + "\n" + message);

    if (options.contains.empty() ||
        searchable.find(options.contains) != std::string::npos) {
      std::cout << FormatTimestamp(seconds, nanoseconds)
                << " id=" << static_cast<unsigned int>(log_id)
                << " uid=" << uid
                << " pid=" << pid
                << " tid=" << tid
                << " prio=" << static_cast<unsigned int>(priority)
                << " tag=" << tag
                << " msg=" << message << '\n';
    }

    ++records;
    offset += length;
  }

  std::cerr << "records=" << records << " skipped_bytes=" << skipped
            << " input_bytes=" << bytes.size() << '\n';
  return 0;
}
