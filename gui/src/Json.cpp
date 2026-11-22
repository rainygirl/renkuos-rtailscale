#include "Json.h"

#include <stdlib.h>
#include <string.h>

namespace {

const Json kNull;
const int kMaxDepth = 64;

struct Parser {
	const char* p;
	const char* end;

	void SkipSpace()
	{
		while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r'))
			p++;
	}

	bool Literal(const char* word)
	{
		size_t length = strlen(word);
		if ((size_t)(end - p) < length || memcmp(p, word, length) != 0)
			return false;
		p += length;
		return true;
	}

	bool Hex4(unsigned& value)
	{
		if (end - p < 4)
			return false;
		value = 0;
		for (int i = 0; i < 4; i++) {
			char c = *p++;
			value <<= 4;
			if (c >= '0' && c <= '9')
				value |= c - '0';
			else if (c >= 'a' && c <= 'f')
				value |= c - 'a' + 10;
			else if (c >= 'A' && c <= 'F')
				value |= c - 'A' + 10;
			else
				return false;
		}
		return true;
	}

	static void AppendUtf8(std::string& out, unsigned cp)
	{
		if (cp < 0x80) {
			out += (char)cp;
		} else if (cp < 0x800) {
			out += (char)(0xC0 | (cp >> 6));
			out += (char)(0x80 | (cp & 0x3F));
		} else if (cp < 0x10000) {
			out += (char)(0xE0 | (cp >> 12));
			out += (char)(0x80 | ((cp >> 6) & 0x3F));
			out += (char)(0x80 | (cp & 0x3F));
		} else {
			out += (char)(0xF0 | (cp >> 18));
			out += (char)(0x80 | ((cp >> 12) & 0x3F));
			out += (char)(0x80 | ((cp >> 6) & 0x3F));
			out += (char)(0x80 | (cp & 0x3F));
		}
	}

	bool ParseString(std::string& out)
	{
		if (p >= end || *p != '"')
			return false;
		p++;
		while (p < end) {
			char c = *p++;
			if (c == '"')
				return true;
			if (c != '\\') {
				out += c;
				continue;
			}
			if (p >= end)
				return false;
			c = *p++;
			switch (c) {
				case 'n': out += '\n'; break;
				case 't': out += '\t'; break;
				case 'r': out += '\r'; break;
				case 'b': out += '\b'; break;
				case 'f': out += '\f'; break;
				case 'u': {
					unsigned cp;
					if (!Hex4(cp))
						return false;
					// A surrogate pair is two \u escapes for one code point.
					if (cp >= 0xD800 && cp < 0xDC00 && end - p >= 6
						&& p[0] == '\\' && p[1] == 'u') {
						const char* mark = p;
						p += 2;
						unsigned low;
						if (Hex4(low) && low >= 0xDC00 && low < 0xE000)
							cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
						else
							p = mark;
					}
					AppendUtf8(out, cp);
					break;
				}
				default: out += c; break; // \" \\ \/
			}
		}
		return false;
	}

	bool ParseValue(Json& out, int depth)
	{
		if (depth > kMaxDepth)
			return false;
		SkipSpace();
		if (p >= end)
			return false;
		char c = *p;
		if (c == '{') {
			p++;
			out.type = Json::Object;
			SkipSpace();
			if (p < end && *p == '}') {
				p++;
				return true;
			}
			while (true) {
				SkipSpace();
				std::string key;
				if (!ParseString(key))
					return false;
				SkipSpace();
				if (p >= end || *p++ != ':')
					return false;
				out.members.emplace_back(std::move(key), Json());
				if (!ParseValue(out.members.back().second, depth + 1))
					return false;
				SkipSpace();
				if (p >= end)
					return false;
				c = *p++;
				if (c == '}')
					return true;
				if (c != ',')
					return false;
			}
		}
		if (c == '[') {
			p++;
			out.type = Json::Array;
			SkipSpace();
			if (p < end && *p == ']') {
				p++;
				return true;
			}
			while (true) {
				out.items.emplace_back();
				if (!ParseValue(out.items.back(), depth + 1))
					return false;
				SkipSpace();
				if (p >= end)
					return false;
				c = *p++;
				if (c == ']')
					return true;
				if (c != ',')
					return false;
			}
		}
		if (c == '"') {
			out.type = Json::String;
			return ParseString(out.string);
		}
		if (Literal("true")) {
			out.type = Json::Bool;
			out.boolean = true;
			return true;
		}
		if (Literal("false")) {
			out.type = Json::Bool;
			return true;
		}
		if (Literal("null"))
			return true;

		const char* start = p;
		while (p < end && (strchr("+-.eE", *p) != NULL || (*p >= '0' && *p <= '9')))
			p++;
		if (p == start)
			return false;
		out.type = Json::Number;
		out.number = strtod(std::string(start, p - start).c_str(), NULL);
		return true;
	}
};

} // namespace


const Json&
Json::operator[](const char* key) const
{
	if (type == Object) {
		for (const auto& member : members) {
			if (member.first == key)
				return member.second;
		}
	}
	return kNull;
}


bool
Json::Parse(const std::string& text, Json& out)
{
	Parser parser = { text.data(), text.data() + text.size() };
	out = Json();
	if (!parser.ParseValue(out, 0))
		return false;
	parser.SkipSpace();
	return parser.p == parser.end;
}
