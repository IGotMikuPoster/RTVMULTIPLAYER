// SPDX-License-Identifier: MIT
// Steam companion. Communicates only over loopback JSON lines.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"

	sw "github.com/plaught-armor/go-steamworks"
)

const (
	roadToVostokAppID = sw.AppId_t(1963610)
	lobbyCreatedID    = int32(513)
	lobbyEnterID      = int32(504)
)

type request struct {
	Command string         `json:"cmd"`
	ID      int            `json:"req_id"`
	Params  map[string]any `json:"params"`
}

type response struct {
	Command string `json:"cmd"`
	ID      int    `json:"req_id,omitempty"`
	OK      bool   `json:"ok"`
	Data    any    `json:"data,omitempty"`
	Error   string `json:"error,omitempty"`
}

// Steam SDK layouts. Explicit padding keeps the 64-bit ABI stable.
type lobbyCreated struct {
	Result  sw.EResult
	_pad    uint32
	LobbyID sw.CSteamID
}

type lobbyEnter struct {
	LobbyID     sw.CSteamID
	Permissions uint32
	Locked      uint8
	_pad        [3]byte
	EnterResult uint32
}

var currentLobby sw.CSteamID
var controlEncoder *json.Encoder

func main() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	port := flag.Int("port", 27108, "loopback control port")
	flag.Parse()
	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)
	if err := sw.Load(); err != nil {
		log.Fatalf("load Steamworks: %v", err)
	}
	if err := sw.Init(); err != nil {
		log.Fatalf("SteamAPI_Init: %v", err)
	}
	defer sw.Shutdown()
	if err := setupManualDispatch(); err != nil {
		log.Fatalf("Steam callback dispatch: %v", err)
	}
	listener, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	defer listener.Close()
	log.Printf("ready app=%d user=%d", roadToVostokAppID, sw.SteamUser().GetSteamID())
	conn, err := listener.Accept()
	if err != nil {
		log.Fatalf("accept: %v", err)
	}
	handleConnection(conn)
	stopP2P()
	if currentLobby != 0 {
		sw.SteamMatchmaking().LeaveLobby(currentLobby)
	}
}

func handleConnection(conn net.Conn) {
	defer conn.Close()
	reader := bufio.NewReaderSize(conn, 64*1024)
	encoder := json.NewEncoder(conn)
	controlEncoder = encoder
	defer func() { controlEncoder = nil }()
	for {
		pumpSteam()
		tickTunnel()
		_ = conn.SetReadDeadline(time.Now().Add(25 * time.Millisecond))
		line, err := reader.ReadString('\n')
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			return
		}
		if len(line) > 64*1024 {
			_ = encodeResponse(encoder, response{Command: "invalid", OK: false, Error: "request too large"})
			return
		}
		var req request
		if json.Unmarshal([]byte(line), &req) != nil || req.Command == "" {
			_ = encodeResponse(encoder, response{Command: "invalid", OK: false, Error: "malformed request"})
			continue
		}
		_ = encodeResponse(encoder, dispatch(req))
	}
}

func dispatch(req request) response {
	ok := func(data any) response { return response{Command: req.Command, ID: req.ID, OK: true, Data: data} }
	fail := func(err string) response { return response{Command: req.Command, ID: req.ID, OK: false, Error: err} }
	switch req.Command {
	case "ping":
		return ok(map[string]any{"version": 1})
	case "get_user":
		user := sw.SteamUser().GetSteamID()
		return ok(map[string]any{
			"steam_id":  strconv.FormatUint(uint64(user), 10),
			"name":      sw.SteamFriends().GetPersonaName(),
			"owns_game": sw.SteamApps().BIsSubscribedApp(roadToVostokAppID),
			"build_id":  sw.SteamApps().GetAppBuildId(),
		})
	case "get_friends":
		friends := sw.SteamFriends()
		items := make([]map[string]any, 0)
		for i, count := 0, friends.GetFriendCount(sw.EFriendFlagImmediate); i < count; i++ {
			id := friends.GetFriendByIndex(i, sw.EFriendFlagImmediate)
			state := friends.GetFriendPersonaState(id)
			if state == sw.EPersonaStateOffline {
				continue
			}
			game, playing := friends.GetFriendGamePlayed(id)
			items = append(items, map[string]any{
				"steam_id": strconv.FormatUint(uint64(id), 10),
				"name":     friends.GetFriendPersonaName(id),
				"state":    int32(state),
				"playing":  playing,
				"lobby_id": strconv.FormatUint(uint64(game.LobbySteamID), 10),
			})
		}
		return ok(items)
	case "create_lobby":
		maxPlayers := clampInt(paramInt(req.Params, "max_players", 8), 2, 8)
		visibility := strings.ToLower(paramString(req.Params, "visibility"))
		lobbyType := sw.ELobbyType_FriendsOnly
		if visibility == "private" {
			lobbyType = sw.ELobbyType_Private
		}
		if visibility == "public" {
			lobbyType = sw.ELobbyType_Public
		}
		call := sw.SteamMatchmaking().CreateLobby(lobbyType, maxPlayers)
		result, failed, err := waitCall[lobbyCreated](call, lobbyCreatedID)
		if err != nil || failed || result.Result != sw.EResultOK || result.LobbyID == 0 {
			return fail(fmt.Sprintf("create lobby failed: %v result=%d", err, result.Result))
		}
		currentLobby = result.LobbyID
		mm := sw.SteamMatchmaking()
		mm.SetLobbyData(currentLobby, "rtv_coop", "1")
		mm.SetLobbyData(currentLobby, "protocol", "2")
		mm.SetLobbyData(currentLobby, "mod_version", "0.5.1")
		mm.SetLobbyData(currentLobby, "host_steam_id", strconv.FormatUint(uint64(sw.SteamUser().GetSteamID()), 10))
		return ok(lobbyDetails(currentLobby))
	case "join_lobby":
		id, err := parseSteamID(paramString(req.Params, "lobby_id"))
		if err != nil {
			return fail(err.Error())
		}
		call := sw.SteamMatchmaking().JoinLobby(id)
		result, failed, waitErr := waitCall[lobbyEnter](call, lobbyEnterID)
		if waitErr != nil || failed || result.EnterResult != 1 {
			return fail(fmt.Sprintf("join lobby failed: %v response=%d", waitErr, result.EnterResult))
		}
		currentLobby = result.LobbyID
		mm := sw.SteamMatchmaking()
		if mm.GetLobbyData(currentLobby, "rtv_coop") != "1" || mm.GetLobbyData(currentLobby, "protocol") != "2" {
			mm.LeaveLobby(currentLobby)
			currentLobby = 0
			return fail("lobby is not a compatible co-op session")
		}
		return ok(lobbyDetails(currentLobby))
	case "leave_lobby":
		if currentLobby != 0 {
			sw.SteamMatchmaking().LeaveLobby(currentLobby)
		}
		currentLobby = 0
		return ok(nil)
	case "invite_friend":
		if currentLobby == 0 {
			return fail("no active Steam lobby")
		}
		id, err := parseSteamID(paramString(req.Params, "steam_id"))
		if err != nil {
			return fail(err.Error())
		}
		if !sw.SteamMatchmaking().InviteUserToLobby(currentLobby, id) {
			return fail("Steam rejected invite")
		}
		return ok(nil)
	case "open_invite_dialog":
		if currentLobby == 0 {
			return fail("host a Steam lobby first")
		}
		sw.SteamFriends().ActivateGameOverlayInviteDialog(currentLobby)
		return ok(nil)
	case "open_friends":
		sw.SteamFriends().ActivateGameOverlay("friends")
		return ok(nil)
	case "lobby_details":
		if currentLobby == 0 {
			return fail("no active Steam lobby")
		}
		return ok(lobbyDetails(currentLobby))
	case "start_p2p_host":
		port := clampInt(paramInt(req.Params, "enet_port", 9058), 1024, 65535)
		data, err := startP2PHost(port)
		if err != nil {
			return fail(err.Error())
		}
		return ok(data)
	case "start_p2p_client":
		hostID, err := parseSteamID(paramString(req.Params, "host_steam_id"))
		if err != nil {
			return fail(err.Error())
		}
		data, err := startP2PClient(hostID)
		if err != nil {
			return fail(err.Error())
		}
		return ok(data)
	case "stop_p2p":
		stopP2P()
		return ok(nil)
	default:
		return fail("unsupported command")
	}
}

func waitCall[T any](call sw.SteamAPICall_t, callbackID int32) (T, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	result := sw.NewCallResult[T](call, callbackID)
	for {
		pumpSteam()
		tickTunnel()
		if _, complete := result.IsComplete(); complete {
			return result.Result()
		}
		select {
		case <-ctx.Done():
			var zero T
			return zero, false, ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

func lobbyDetails(id sw.CSteamID) map[string]any {
	mm := sw.SteamMatchmaking()
	owner := mm.GetLobbyOwner(id)
	return map[string]any{
		"lobby_id":       strconv.FormatUint(uint64(id), 10),
		"owner_steam_id": strconv.FormatUint(uint64(owner), 10),
		"members":        mm.GetNumLobbyMembers(id),
		"limit":          mm.GetLobbyMemberLimit(id),
	}
}

func parseSteamID(value string) (sw.CSteamID, error) {
	id, err := strconv.ParseUint(strings.TrimSpace(value), 10, 64)
	if err != nil || id == 0 {
		return 0, errors.New("invalid Steam ID")
	}
	return sw.CSteamID(id), nil
}

func paramString(params map[string]any, key string) string {
	if params == nil {
		return ""
	}
	return fmt.Sprint(params[key])
}

func paramInt(params map[string]any, key string, fallback int) int {
	if params == nil {
		return fallback
	}
	switch value := params[key].(type) {
	case float64:
		return int(value)
	case int:
		return value
	default:
		parsed, err := strconv.Atoi(fmt.Sprint(value))
		if err == nil {
			return parsed
		}
	}
	return fallback
}

func clampInt(value, minimum, maximum int) int {
	if value < minimum {
		return minimum
	}
	if value > maximum {
		return maximum
	}
	return value
}

func init() {
	// The helper only needs Steam's client API; never silently fall back to the
	// Spacewar development App ID in distributed builds.
	if os.Getenv("SteamAppId") == "" {
		_ = os.Setenv("SteamAppId", strconv.Itoa(int(roadToVostokAppID)))
	}
	if os.Getenv("SteamGameId") == "" {
		_ = os.Setenv("SteamGameId", strconv.Itoa(int(roadToVostokAppID)))
	}
}
