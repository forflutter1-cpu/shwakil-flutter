#pragma once

#include <Windows.h>

#include <string>
#include <utility>

namespace shwakil_atl_compat {

inline std::wstring toWide(const char* value) {
  if (value == nullptr) {
    return {};
  }

  const int required = MultiByteToWideChar(CP_ACP, 0, value, -1, nullptr, 0);
  if (required <= 0) {
    return {};
  }

  std::wstring result(static_cast<size_t>(required), L'\0');
  if (MultiByteToWideChar(CP_ACP, 0, value, -1, result.data(), required) != required) {
    return {};
  }
  result.resize(static_cast<size_t>(required - 1));
  return result;
}

inline std::string toNarrow(const wchar_t* value) {
  if (value == nullptr) {
    return {};
  }

  const int required = WideCharToMultiByte(CP_ACP, 0, value, -1, nullptr, 0, nullptr, nullptr);
  if (required <= 0) {
    return {};
  }

  std::string result(static_cast<size_t>(required), '\0');
  if (WideCharToMultiByte(CP_ACP, 0, value, -1, result.data(), required, nullptr, nullptr) != required) {
    return {};
  }
  result.resize(static_cast<size_t>(required - 1));
  return result;
}

}  // namespace shwakil_atl_compat

class CA2W {
 private:
  std::wstring value_;

 public:
  explicit CA2W(const char* value)
      : value_(shwakil_atl_compat::toWide(value)), m_psz(value_.data()) {}

  CA2W(const CA2W& other)
      : value_(other.value_), m_psz(value_.data()) {}

  CA2W(CA2W&& other) noexcept
      : value_(std::move(other.value_)), m_psz(value_.data()) {}

  wchar_t* m_psz;
};

class CW2A {
 public:
  explicit CW2A(const wchar_t* value)
      : value_(shwakil_atl_compat::toNarrow(value)) {}

  operator std::string() const { return value_; }

 private:
  std::string value_;
};
