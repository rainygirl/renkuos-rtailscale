// User-visible strings: English and Korean. The key is the English text.
#pragma once

#include <LocaleRoster.h>
#include <Message.h>
#include <String.h>

#include <string.h>

struct Translation {
	const char* en;
	const char* ko;
};

static const Translation kTranslations[] = {
	{ "Connected", "연결됨" },
	{ "Disconnected", "연결 끊김" },
	{ "Connecting…", "연결 중…" },
	{ "Sign-in required", "로그인 필요" },
	{ "Waiting for approval", "승인 대기 중" },
	{ "Starting…", "시작하는 중…" },
	{ "Tailscale service is not running", "Tailscale 서비스가 실행 중이 아닙니다" },
	{ "Connect", "연결" },
	{ "Disconnect", "연결 끊기" },
	{ "Sign in…", "로그인…" },
	{ "Sign out", "로그아웃" },
	{ "Start service", "서비스 시작" },
	{ "Open this link on any device to sign in:", "아무 기기에서나 이 링크를 열어 로그인하세요:" },
	{ "Open in browser", "브라우저에서 열기" },
	{ "Copy link", "링크 복사" },
	{ "Copy IP", "IP 복사" },
	{ "SSH", "SSH" },
	{ "User:", "사용자:" },
	{ "direct", "직접 연결" },
	{ "relay", "릴레이" },
	{ "offline", "오프라인" },
	{ "No other devices in this tailnet yet.", "이 tailnet에 다른 기기가 아직 없습니다." },
	{ "Cancel", "취소" },
	{ "OK", "확인" },
	{ "Sign out of this tailnet? This device will have to sign in again.",
		"이 tailnet에서 로그아웃할까요? 이 기기는 다시 로그인해야 합니다." },
	{ "tailscaled-service was not found. Install the renkuos-rtailscale package first.",
		"tailscaled-service를 찾지 못했습니다. 먼저 renkuos-rtailscale 패키지를 설치하세요." },
	{ "The Tailscale service did not answer.", "Tailscale 서비스가 응답하지 않습니다." },
	{ "Apps reach the tailnet through SOCKS5 127.0.0.1:1055 or HTTP proxy 127.0.0.1:1056.",
		"앱은 SOCKS5 127.0.0.1:1055 또는 HTTP 프록시 127.0.0.1:1056으로 tailnet에 접속합니다." },
};


inline bool
UseKorean()
{
	static int cached = -1;
	if (cached < 0) {
		cached = 0;
		BMessage languages;
		BString first;
		if (BLocaleRoster::Default()->GetPreferredLanguages(&languages) == B_OK
			&& languages.FindString("language", &first) == B_OK
			&& first.StartsWith("ko")) {
			cached = 1;
		}
	}
	return cached == 1;
}


inline const char*
T(const char* english)
{
	if (!UseKorean())
		return english;
	for (const Translation& entry : kTranslations) {
		if (strcmp(entry.en, english) == 0)
			return entry.ko;
	}
	return english;
}
