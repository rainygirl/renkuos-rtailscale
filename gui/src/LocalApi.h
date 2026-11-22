// tailscaled's LocalAPI, spoken over its Unix socket, and the service that
// provides it.
#pragma once

#include <string>
#include <vector>

struct Peer {
	std::string name;
	std::string ip;
	std::string os;
	bool online = false;
	bool direct = false; // a direct path, as opposed to a DERP relay
};

struct Status {
	bool reachable = false; // the daemon answered
	std::string backend;    // NoState, NeedsLogin, Starting, Running, Stopped...
	std::string authUrl;
	std::string version;
	std::string selfName;
	std::string selfIp;
	std::string tailnet;
	std::string health;
	std::vector<Peer> peers; // online first, then by name
};

namespace localapi {

// Default socket of the Haiku port: ~/config/settings/tailscale/tailscaled.sock
std::string SocketPath();
std::string SettingsDirectory();

// One request. Returns the HTTP status, or -1 when the daemon is unreachable.
int Request(const char* method, const char* path, const std::string& body,
	std::string& response);

Status FetchStatus();
bool SetWantRunning(bool on);
bool StartLogin();
bool Logout();

// Starts tailscaled through the tailscaled-service script. False when the
// script is not installed.
bool StartService();

// "tailscale" next to the installed daemon, for the ssh ProxyCommand.
std::string CliPath();

} // namespace localapi
