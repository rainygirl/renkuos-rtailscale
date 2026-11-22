// R Tailscale: a window onto the tailscaled service running on this machine.
//
// It talks to the daemon's LocalAPI directly over its Unix socket, so it needs
// no helper process and shows the same state "tailscale status" would.

#include "LocalApi.h"
#include "Strings.h"

#include <Alert.h>
#include <Application.h>
#include <Button.h>
#include <Clipboard.h>
#include <Font.h>
#include <GroupView.h>
#include <LayoutBuilder.h>
#include <ListItem.h>
#include <ListView.h>
#include <Messenger.h>
#include <OS.h>
#include <Roster.h>
#include <ScrollView.h>
#include <StringView.h>
#include <TextControl.h>
#include <Window.h>

#include <stdlib.h>
#include <string.h>

namespace {

const char* const kSignature = "application/x-vnd.rainygirl-RTailscale";
const char* const kTerminalSignature = "application/x-vnd.Haiku-Terminal";

// Which of the two is shown depends on how the daemon reaches the system.
const char* const kProxyNote
	= "Apps reach the tailnet through SOCKS5 127.0.0.1:1055 or HTTP proxy 127.0.0.1:1056.";
const char* const kTunNote
	= "Every app reaches the tailnet directly, by address or by MagicDNS name.";

const bigtime_t kPollInterval = 2000000;

enum {
	kMsgStatus = 'stat',
	kMsgPrimary = 'prim',
	kMsgSignOut = 'sout',
	kMsgOpenLink = 'olnk',
	kMsgCopyLink = 'clnk',
	kMsgCopyIp = 'cpip',
	kMsgSsh = 'ssh_',
	kMsgSelection = 'slct',
	kMsgActionFailed = 'afal',
};

enum Action {
	kActionConnect,
	kActionDisconnect,
	kActionSignIn,
	kActionSignOut,
};

const rgb_color kGreen = { 52, 168, 83, 255 };
const rgb_color kAmber = { 230, 160, 30, 255 };
const rgb_color kGray = { 150, 150, 150, 255 };
const rgb_color kRed = { 210, 70, 60, 255 };


bool
OnlyCharacters(const std::string& text, const char* allowed)
{
	return !text.empty() && text.find_first_not_of(allowed) == std::string::npos;
}


void
CopyToClipboard(const std::string& text)
{
	if (!be_clipboard->Lock())
		return;
	be_clipboard->Clear();
	BMessage* clip = be_clipboard->Data();
	if (clip != NULL) {
		clip->AddData("text/plain", B_MIME_TYPE, text.data(), text.size());
		be_clipboard->Commit();
	}
	be_clipboard->Unlock();
}


void
OpenInBrowser(const std::string& url)
{
	// What BUrl::OpenWithPreferredApplication does, without depending on
	// which BUrl constructors this Haiku revision has.
	const char* arguments[] = { url.c_str() };
	be_roster->Launch("application/x-vnd.Be.URL.https", 1, arguments);
}


// A filled circle in the state's color.
class Dot : public BView {
public:
	Dot()
		:
		BView("dot", B_WILL_DRAW | B_FULL_UPDATE_ON_RESIZE),
		fColor(kGray)
	{
		SetViewUIColor(B_PANEL_BACKGROUND_COLOR);
		float size = be_plain_font->Size();
		SetExplicitSize(BSize(size, size));
	}

	void SetColor(rgb_color color)
	{
		if (color != fColor) {
			fColor = color;
			Invalidate();
		}
	}

	void Draw(BRect) override
	{
		SetHighColor(fColor);
		FillEllipse(Bounds());
	}

private:
	rgb_color fColor;
};


class PeerItem : public BListItem {
public:
	explicit PeerItem(const Peer& peer)
		:
		fPeer(peer)
	{
	}

	const Peer& Info() const { return fPeer; }

	void Update(BView* owner, const BFont* font) override
	{
		BListItem::Update(owner, font);
		font_height height;
		font->GetHeight(&height);
		fBaseline = height.ascent;
		SetHeight((height.ascent + height.descent + height.leading) * 1.7f);
	}

	void DrawItem(BView* owner, BRect frame, bool) override
	{
		rgb_color background = ui_color(IsSelected()
			? B_LIST_SELECTED_BACKGROUND_COLOR : B_LIST_BACKGROUND_COLOR);
		rgb_color text = ui_color(IsSelected()
			? B_LIST_SELECTED_ITEM_TEXT_COLOR : B_LIST_ITEM_TEXT_COLOR);
		rgb_color dim = mix_color(text, background, 110);

		owner->SetLowColor(background);
		owner->FillRect(frame, B_SOLID_LOW);

		float em = be_plain_font->Size();
		float radius = em * 0.3f;
		float middle = (frame.top + frame.bottom) / 2;
		owner->SetHighColor(fPeer.online ? kGreen : kGray);
		owner->FillEllipse(BPoint(frame.left + em, middle), radius, radius);

		float baseline = middle + fBaseline / 2 - 1;
		float nameLeft = frame.left + em * 2;
		float ipLeft = frame.left + frame.Width() * 0.42f;

		// Right column first: its width decides where the others truncate.
		BString right(fPeer.os.c_str());
		const char* path = !fPeer.online ? T("offline")
			: fPeer.direct ? T("direct") : T("relay");
		if (right.Length() > 0)
			right << "  ";
		right << path;
		float rightWidth = owner->StringWidth(right.String());
		float rightLeft = frame.right - em - rightWidth;
		owner->SetHighColor(dim);
		owner->DrawString(right.String(), BPoint(rightLeft, baseline));

		BString ip(fPeer.ip.c_str());
		owner->TruncateString(&ip, B_TRUNCATE_END, rightLeft - ipLeft - em);
		owner->DrawString(ip.String(), BPoint(ipLeft, baseline));

		BString name(fPeer.name.c_str());
		owner->TruncateString(&name, B_TRUNCATE_END, ipLeft - nameLeft - em);
		owner->SetHighColor(fPeer.online ? text : dim);
		owner->DrawString(name.String(), BPoint(nameLeft, baseline));
	}

private:
	Peer fPeer;
	float fBaseline = 0;
};


class MainWindow : public BWindow {
public:
	MainWindow();
	~MainWindow() override;

	void MessageReceived(BMessage* message) override;
	bool QuitRequested() override;

private:
	static int32 _PollLoop(void* data);
	static int32 _ActionThread(void* data);

	void _Run(Action action);
	void _Apply(const Status& status);
	void _RebuildPeers(const Status& status);
	void _UpdateSelection();
	const Peer* _SelectedPeer() const;
	void _Primary();
	void _OpenSsh();

	Dot* fDot;
	BStringView* fState;
	BStringView* fDetail;
	BStringView* fHealth;
	BButton* fPrimary;
	BGroupView* fLoginBox;
	BTextControl* fLink;
	BListView* fPeers;
	BStringView* fEmpty;
	BTextControl* fUser;
	BButton* fSsh;
	BButton* fCopyIp;
	BButton* fSignOut;
	BStringView* fProxy;
	BStringView* fVersion;

	Status fStatus;
	std::string fPeerKey;   // what the list currently shows
	bool fOpenLinkWhenReady;
	sem_id fWake;           // released to make the poller run now
	thread_id fPoller;
};


struct PollContext {
	BMessenger target;
	sem_id wake;
};

struct ActionContext {
	Action action;
	BMessenger target;
	sem_id wake;
};


MainWindow::MainWindow()
	:
	BWindow(BRect(0, 0, 10, 10), "R Tailscale", B_TITLED_WINDOW,
		B_AUTO_UPDATE_SIZE_LIMITS | B_ASYNCHRONOUS_CONTROLS | B_QUIT_ON_WINDOW_CLOSE),
	fOpenLinkWhenReady(false)
{
	float em = be_plain_font->Size();

	fDot = new Dot();
	fState = new BStringView("state", T("Starting…"));
	BFont bold(be_bold_font);
	bold.SetSize(em * 1.25f);
	fState->SetFont(&bold);
	fPrimary = new BButton("primary", T("Connect"), new BMessage(kMsgPrimary));
	fPrimary->SetEnabled(false);

	fDetail = new BStringView("detail", " ");
	fDetail->SetHighUIColor(B_PANEL_TEXT_COLOR, B_DARKEN_1_TINT);
	fDetail->SetTruncation(B_TRUNCATE_END);
	fDetail->SetExplicitMinSize(BSize(em * 10, B_SIZE_UNSET));
	fHealth = new BStringView("health", "");
	fHealth->SetHighColor(kRed);
	fHealth->SetTruncation(B_TRUNCATE_END);
	fHealth->SetExplicitMinSize(BSize(em * 10, B_SIZE_UNSET));
	fHealth->Hide();

	fLink = new BTextControl("link", NULL, "", NULL);
	fLink->TextView()->MakeEditable(false);
	fLoginBox = new BGroupView(B_VERTICAL, B_USE_HALF_ITEM_SPACING);
	BLayoutBuilder::Group<>(fLoginBox)
		.Add(new BStringView("linkLabel", T("Open this link on any device to sign in:")))
		.Add(fLink)
		.AddGroup(B_HORIZONTAL)
			.Add(new BButton("open", T("Open in browser"), new BMessage(kMsgOpenLink)))
			.Add(new BButton("copy", T("Copy link"), new BMessage(kMsgCopyLink)))
			.AddGlue()
		.End();
	fLoginBox->Hide();

	fPeers = new BListView("peers", B_SINGLE_SELECTION_LIST);
	fPeers->SetSelectionMessage(new BMessage(kMsgSelection));
	fPeers->SetInvocationMessage(new BMessage(kMsgCopyIp));
	BScrollView* scroll = new BScrollView("scroll", fPeers, 0, false, true);
	scroll->SetExplicitMinSize(BSize(em * 34, em * 16));
	fEmpty = new BStringView("empty", T("No other devices in this tailnet yet."));
	fEmpty->SetHighUIColor(B_PANEL_TEXT_COLOR, B_DARKEN_1_TINT);
	fEmpty->Hide();

	const char* user = getenv("USER");
	fUser = new BTextControl("user", T("User:"), user != NULL ? user : "", NULL);
	fUser->SetExplicitMinSize(BSize(em * 12, B_SIZE_UNSET));
	fSsh = new BButton("ssh", T("SSH"), new BMessage(kMsgSsh));
	fCopyIp = new BButton("copyIp", T("Copy IP"), new BMessage(kMsgCopyIp));
	fSignOut = new BButton("signOut", T("Sign out"), new BMessage(kMsgSignOut));
	fSsh->SetEnabled(false);
	fCopyIp->SetEnabled(false);
	fSignOut->SetEnabled(false);

	fProxy = new BStringView("proxy", T(kProxyNote));
	BFont small(be_plain_font);
	small.SetSize(em * 0.9f);
	fProxy->SetFont(&small);
	fProxy->SetHighUIColor(B_PANEL_TEXT_COLOR, B_DARKEN_1_TINT);
	fVersion = new BStringView("version", "");
	fVersion->SetFont(&small);
	fVersion->SetHighUIColor(B_PANEL_TEXT_COLOR, B_DARKEN_1_TINT);

	BLayoutBuilder::Group<>(this, B_VERTICAL, B_USE_DEFAULT_SPACING)
		.SetInsets(B_USE_WINDOW_SPACING)
		.AddGroup(B_HORIZONTAL)
			.Add(fDot)
			.Add(fState)
			.AddGlue()
			.Add(fPrimary)
		.End()
		.Add(fDetail)
		.Add(fHealth)
		.Add(fLoginBox)
		.Add(scroll, 10)
		.Add(fEmpty)
		.AddGroup(B_HORIZONTAL)
			.Add(fUser)
			.Add(fSsh)
			.Add(fCopyIp)
			.AddGlue()
			.Add(fSignOut)
		.End()
		.AddGroup(B_VERTICAL, 0)
			.Add(fProxy)
			.Add(fVersion)
		.End();

	CenterOnScreen();

	fWake = create_sem(0, "rtailscale wake");
	PollContext* context = new PollContext { BMessenger(this), fWake };
	fPoller = spawn_thread(_PollLoop, "status poller", B_NORMAL_PRIORITY, context);
	if (fPoller >= 0)
		resume_thread(fPoller);
	else
		delete context;
}


MainWindow::~MainWindow()
{
	// Deleting the semaphore is also what ends the poller's wait.
	delete_sem(fWake);
}


bool
MainWindow::QuitRequested()
{
	be_app->PostMessage(B_QUIT_REQUESTED);
	return true;
}


int32
MainWindow::_PollLoop(void* data)
{
	PollContext* context = (PollContext*)data;
	while (true) {
		Status* status = new Status(localapi::FetchStatus());
		BMessage message(kMsgStatus);
		message.AddPointer("status", status);
		if (context->target.SendMessage(&message) != B_OK) {
			delete status;
			break; // the window is gone
		}
		status_t result = acquire_sem_etc(context->wake, 1, B_RELATIVE_TIMEOUT,
			kPollInterval);
		if (result != B_OK && result != B_TIMED_OUT && result != B_INTERRUPTED)
			break; // the semaphore was deleted
	}
	delete context;
	return 0;
}


int32
MainWindow::_ActionThread(void* data)
{
	ActionContext* context = (ActionContext*)data;
	bool ok = false;
	switch (context->action) {
		case kActionConnect:
			ok = localapi::SetWantRunning(true);
			break;
		case kActionDisconnect:
			ok = localapi::SetWantRunning(false);
			break;
		case kActionSignIn:
			ok = localapi::StartLogin();
			break;
		case kActionSignOut:
			ok = localapi::Logout();
			break;
	}
	if (!ok)
		context->target.SendMessage(kMsgActionFailed);
	release_sem(context->wake); // show the new state without waiting a poll
	delete context;
	return 0;
}


// LocalAPI calls block on the socket, so they never run on the window thread.
void
MainWindow::_Run(Action action)
{
	ActionContext* context = new ActionContext { action, BMessenger(this), fWake };
	thread_id thread = spawn_thread(_ActionThread, "localapi action",
		B_NORMAL_PRIORITY, context);
	if (thread >= 0)
		resume_thread(thread);
	else
		delete context;
}


void
MainWindow::MessageReceived(BMessage* message)
{
	switch (message->what) {
		case kMsgStatus: {
			Status* status = NULL;
			if (message->FindPointer("status", (void**)&status) == B_OK
				&& status != NULL) {
				_Apply(*status);
				delete status;
			}
			break;
		}
		case kMsgPrimary:
			_Primary();
			break;
		case kMsgSignOut: {
			BAlert* alert = new BAlert("R Tailscale",
				T("Sign out of this tailnet? This device will have to sign in again."),
				T("Cancel"), T("Sign out"), NULL, B_WIDTH_AS_USUAL, B_WARNING_ALERT);
			alert->SetShortcut(0, B_ESCAPE);
			if (alert->Go() == 1)
				_Run(kActionSignOut);
			break;
		}
		case kMsgOpenLink:
			if (!fStatus.authUrl.empty())
				OpenInBrowser(fStatus.authUrl);
			break;
		case kMsgCopyLink:
			if (!fStatus.authUrl.empty())
				CopyToClipboard(fStatus.authUrl);
			break;
		case kMsgCopyIp: {
			const Peer* peer = _SelectedPeer();
			if (peer != NULL && !peer->ip.empty())
				CopyToClipboard(peer->ip);
			break;
		}
		case kMsgSsh:
			_OpenSsh();
			break;
		case kMsgSelection:
			_UpdateSelection();
			break;
		case kMsgActionFailed:
			(new BAlert("R Tailscale", T("The Tailscale service did not answer."),
				T("OK"), NULL, NULL, B_WIDTH_AS_USUAL, B_WARNING_ALERT))->Go(NULL);
			break;
		default:
			BWindow::MessageReceived(message);
	}
}


void
MainWindow::_Primary()
{
	if (!fStatus.reachable) {
		if (!localapi::StartService()) {
			(new BAlert("R Tailscale",
				T("tailscaled-service was not found. Install the renkuos-rtailscale package first."),
				T("OK"), NULL, NULL, B_WIDTH_AS_USUAL, B_STOP_ALERT))->Go(NULL);
		}
		fPrimary->SetEnabled(false); // until the next status says otherwise
		return;
	}
	if (fStatus.backend == "NeedsLogin") {
		// The daemon produces the link a moment later; open it once it does.
		fOpenLinkWhenReady = true;
		_Run(kActionSignIn);
	} else if (fStatus.backend == "Running" || fStatus.backend == "Starting") {
		_Run(kActionDisconnect);
	} else {
		_Run(kActionConnect);
	}
}


void
MainWindow::_Apply(const Status& status)
{
	bool linkAppeared = fStatus.authUrl.empty() && !status.authUrl.empty();
	fStatus = status;

	const char* state = T("Starting…");
	const char* primary = T("Connect");
	rgb_color color = kGray;
	bool primaryEnabled = true;

	if (!status.reachable) {
		state = T("Tailscale service is not running");
		primary = T("Start service");
		color = kRed;
	} else if (status.backend == "Running") {
		state = T("Connected");
		primary = T("Disconnect");
		color = kGreen;
	} else if (status.backend == "Starting") {
		state = T("Connecting…");
		primary = T("Disconnect");
		color = kAmber;
	} else if (status.backend == "NeedsLogin") {
		state = T("Sign-in required");
		primary = T("Sign in…");
		color = kAmber;
	} else if (status.backend == "NeedsMachineAuth") {
		state = T("Waiting for approval");
		color = kAmber;
		primaryEnabled = false;
	} else if (status.backend == "Stopped") {
		state = T("Disconnected");
	} else {
		primaryEnabled = false; // NoState: the daemon is still loading
	}

	fDot->SetColor(color);
	fState->SetText(state);
	fPrimary->SetLabel(primary);
	fPrimary->SetEnabled(primaryEnabled);

	BString detail;
	for (const std::string* part : { &status.selfName, &status.selfIp, &status.tailnet }) {
		if (part->empty())
			continue;
		if (detail.Length() > 0)
			detail << "  ·  ";
		detail << part->c_str();
	}
	fDetail->SetText(detail.Length() > 0 ? detail.String() : " ");

	bool showHealth = !status.health.empty();
	fHealth->SetText(status.health.c_str());
	if (showHealth == fHealth->IsHidden(fHealth)) {
		if (showHealth)
			fHealth->Show();
		else
			fHealth->Hide();
	}

	bool signedIn = status.reachable && status.backend != "NeedsLogin"
		&& status.backend != "NoState" && !status.backend.empty();
	fSignOut->SetEnabled(signedIn);

	// The link is only useful until the sign-in completes.
	bool showLink = !status.authUrl.empty() && status.backend != "Running";
	if (showLink && fLink->Text() != status.authUrl)
		fLink->SetText(status.authUrl.c_str());
	if (showLink == fLoginBox->IsHidden(fLoginBox)) {
		if (showLink)
			fLoginBox->Show();
		else
			fLoginBox->Hide();
	}
	if (linkAppeared && fOpenLinkWhenReady) {
		fOpenLinkWhenReady = false;
		OpenInBrowser(status.authUrl);
	}

	fVersion->SetText(status.version.c_str());
	fProxy->SetText(T(status.tun ? kTunNote : kProxyNote));
	_RebuildPeers(status);
}


void
MainWindow::_RebuildPeers(const Status& status)
{
	// Rebuilding on every poll would drop the selection and flicker, so only
	// do it when something a row shows has changed.
	std::string key;
	for (const Peer& peer : status.peers) {
		key += peer.name + '\t' + peer.ip + '\t' + peer.os
			+ (peer.online ? "\t1" : "\t0") + (peer.direct ? "d\n" : "r\n");
	}
	if (key != fPeerKey) {
		fPeerKey = key;
		std::string selected;
		if (const Peer* peer = _SelectedPeer())
			selected = peer->ip;

		for (int32 i = fPeers->CountItems() - 1; i >= 0; i--)
			delete fPeers->RemoveItem(i);
		int32 select = -1;
		for (const Peer& peer : status.peers) {
			if (!selected.empty() && peer.ip == selected)
				select = fPeers->CountItems();
			fPeers->AddItem(new PeerItem(peer));
		}
		if (select >= 0)
			fPeers->Select(select);
	}

	bool showEmpty = status.backend == "Running" && status.peers.empty();
	if (showEmpty == fEmpty->IsHidden(fEmpty)) {
		if (showEmpty)
			fEmpty->Show();
		else
			fEmpty->Hide();
	}
	_UpdateSelection();
}


const Peer*
MainWindow::_SelectedPeer() const
{
	PeerItem* item = dynamic_cast<PeerItem*>(
		fPeers->ItemAt(fPeers->CurrentSelection()));
	return item != NULL ? &item->Info() : NULL;
}


void
MainWindow::_UpdateSelection()
{
	const Peer* peer = _SelectedPeer();
	fCopyIp->SetEnabled(peer != NULL && !peer->ip.empty());
	fSsh->SetEnabled(peer != NULL && peer->online && !peer->ip.empty()
		&& fStatus.backend == "Running");
}


void
MainWindow::_OpenSsh()
{
	const Peer* peer = _SelectedPeer();
	if (peer == NULL)
		return;
	// Both values end up inside a shell command line. The address comes from
	// the daemon and the user name from a text field: accept only what an
	// address or a login name can contain.
	std::string user = fUser->Text();
	if (!OnlyCharacters(peer->ip, "0123456789abcdefABCDEF.:")
		|| (!user.empty()
			&& !OnlyCharacters(user,
				"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"))) {
		return;
	}

	// Carried by "tailscale nc": in userspace-networking mode the system has
	// no route to tailnet addresses, and with a TUN interface this works just
	// the same.
	std::string target = user.empty() ? peer->ip : user + "@" + peer->ip;
	std::string command = "ssh -o ProxyCommand='" + localapi::CliPath()
		+ " nc %h %p' " + target
		+ "; echo; echo '[ssh ended - press Enter to close]'; read line";
	std::string title = "ssh " + peer->name;
	const char* arguments[] = { "-t", title.c_str(), "/bin/sh", "-c", command.c_str() };
	be_roster->Launch(kTerminalSignature, 5, arguments);
}


class App : public BApplication {
public:
	App()
		:
		BApplication(kSignature)
	{
	}

	void ReadyToRun() override
	{
		(new MainWindow())->Show();
	}
};

} // namespace


int
main()
{
	App app;
	app.Run();
	return 0;
}
