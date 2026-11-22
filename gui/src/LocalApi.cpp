#include "LocalApi.h"

#include "Json.h"

#include <FindDirectory.h>
#include <OS.h>
#include <Path.h>
#include <image.h>

#include <algorithm>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

extern char** environ;

namespace localapi {

namespace {

// The Go server answers a status request in milliseconds; this only bounds a
// daemon that has stopped responding.
const int kTimeoutSeconds = 6;

// Where "pkgman install", a user-level package and a manual install put
// binaries, in the order they should win.
const char* const kBinDirectories[] = {
	"/boot/home/config/non-packaged/bin",
	"/boot/home/config/bin",
	"/boot/system/non-packaged/bin",
	"/boot/system/bin",
};

std::string
FindBinary(const char* name)
{
	for (const char* directory : kBinDirectories) {
		std::string path = std::string(directory) + "/" + name;
		if (access(path.c_str(), X_OK) == 0)
			return path;
	}
	return "";
}

bool
WriteAll(int fd, const std::string& data)
{
	size_t done = 0;
	while (done < data.size()) {
		ssize_t n = send(fd, data.data() + done, data.size() - done, 0);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return false;
		done += n;
	}
	return true;
}

} // namespace


std::string
SettingsDirectory()
{
	BPath path;
	if (find_directory(B_USER_SETTINGS_DIRECTORY, &path) != B_OK)
		return "/boot/home/config/settings/tailscale";
	path.Append("tailscale");
	return path.Path();
}


std::string
SocketPath()
{
	return SettingsDirectory() + "/tailscaled.sock";
}


int
Request(const char* method, const char* path, const std::string& body,
	std::string& response)
{
	response.clear();

	std::string socketPath = SocketPath();
	sockaddr_un address;
	memset(&address, 0, sizeof(address));
	address.sun_family = AF_UNIX;
	if (socketPath.size() >= sizeof(address.sun_path))
		return -1;
	strcpy(address.sun_path, socketPath.c_str());

	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	timeval timeout = { kTimeoutSeconds, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
	if (connect(fd, (sockaddr*)&address, sizeof(address)) != 0) {
		close(fd);
		return -1;
	}

	// HTTP/1.0 makes the server close the connection after the response, so
	// the body is simply everything up to end of file. The Host value is the
	// one tailscaled accepts for its Unix socket.
	char header[512];
	snprintf(header, sizeof(header),
		"%s %s HTTP/1.0\r\n"
		"Host: local-tailscaled.sock\r\n"
		"Content-Type: application/json\r\n"
		"Content-Length: %zu\r\n\r\n",
		method, path, body.size());
	if (!WriteAll(fd, std::string(header) + body)) {
		close(fd);
		return -1;
	}

	std::string raw;
	char buffer[16384];
	while (true) {
		ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			break;
		raw.append(buffer, n);
	}
	close(fd);

	// "HTTP/1.0 200 OK"
	int status = -1;
	if (sscanf(raw.c_str(), "HTTP/%*d.%*d %d", &status) != 1)
		return -1;
	size_t bodyStart = raw.find("\r\n\r\n");
	if (bodyStart != std::string::npos)
		response = raw.substr(bodyStart + 4);
	return status;
}


Status
FetchStatus()
{
	Status status;
	std::string text;
	if (Request("GET", "/localapi/v0/status", "", text) != 200)
		return status;
	Json root;
	if (!Json::Parse(text, root))
		return status;

	status.reachable = true;
	status.backend = root["BackendState"].Str();
	status.tun = root["TUN"].IsTrue();
	status.authUrl = root["AuthURL"].Str();
	status.version = root["Version"].Str();
	status.tailnet = root["CurrentTailnet"]["Name"].Str();

	const Json& self = root["Self"];
	status.selfName = self["HostName"].Str();
	const Json& selfIps = root["TailscaleIPs"];
	if (!selfIps.items.empty())
		status.selfIp = selfIps.items[0].Str();

	for (const Json& line : root["Health"].items) {
		if (!status.health.empty())
			status.health += "  ";
		status.health += line.Str();
	}

	for (const auto& member : root["Peer"].members) {
		const Json& node = member.second;
		Peer peer;
		peer.name = node["HostName"].Str();
		// The MagicDNS name is the one the tailnet actually uses; HostName
		// is only what the machine calls itself and can repeat.
		const std::string& dnsName = node["DNSName"].Str();
		size_t dot = dnsName.find('.');
		if (dot != std::string::npos && dot > 0)
			peer.name = dnsName.substr(0, dot);
		const Json& ips = node["TailscaleIPs"];
		if (!ips.items.empty())
			peer.ip = ips.items[0].Str();
		peer.os = node["OS"].Str();
		peer.online = node["Online"].IsTrue();
		peer.direct = !node["CurAddr"].Str().empty();
		status.peers.push_back(peer);
	}
	std::sort(status.peers.begin(), status.peers.end(),
		[](const Peer& a, const Peer& b) {
			if (a.online != b.online)
				return a.online;
			return strcasecmp(a.name.c_str(), b.name.c_str()) < 0;
		});
	return status;
}


bool
SetWantRunning(bool on)
{
	std::string response;
	std::string body = on
		? "{\"WantRunning\":true,\"WantRunningSet\":true}"
		: "{\"WantRunning\":false,\"WantRunningSet\":true}";
	return Request("PATCH", "/localapi/v0/prefs", body, response) == 200;
}


bool
StartLogin()
{
	std::string response;
	int status = Request("POST", "/localapi/v0/login-interactive", "", response);
	return status == 200 || status == 204;
}


bool
Logout()
{
	std::string response;
	int status = Request("POST", "/localapi/v0/logout", "", response);
	return status == 200 || status == 204;
}


bool
StartService()
{
	std::string script = FindBinary("tailscaled-service");
	if (script.empty())
		return false;
	// A team of its own: the daemon must outlive this window.
	const char* arguments[] = { "/bin/sh", script.c_str(), NULL };
	thread_id thread = load_image(2, arguments, (const char**)environ);
	if (thread < 0)
		return false;
	return resume_thread(thread) == B_OK;
}


std::string
CliPath()
{
	std::string path = FindBinary("tailscale");
	return path.empty() ? "tailscale" : path;
}

} // namespace localapi
