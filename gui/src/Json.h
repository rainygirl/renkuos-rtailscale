// A small JSON reader: enough for tailscaled's LocalAPI responses.
#pragma once

#include <string>
#include <utility>
#include <vector>

struct Json {
	enum Type { Null, Bool, Number, String, Array, Object };

	Type type = Null;
	bool boolean = false;
	double number = 0;
	std::string string;
	std::vector<Json> items;
	std::vector<std::pair<std::string, Json>> members;

	// Member lookup; a missing key (or a non-object) gives a Null value, so
	// chains like status["Self"]["HostName"].Str() need no checks.
	const Json& operator[](const char* key) const;

	const std::string& Str() const { return string; }
	bool IsTrue() const { return type == Bool && boolean; }

	// False when the text is not one complete JSON value.
	static bool Parse(const std::string& text, Json& out);
};
