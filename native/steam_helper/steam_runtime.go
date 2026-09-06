// SPDX-License-Identifier: MIT
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"unsafe"

	sw "github.com/plaught-armor/go-steamworks"
)

const gameLobbyJoinRequestedID = int32(333)

type callbackMessage struct {
	SteamUser int32
	Callback  int32
	Param     uintptr
	ParamSize int32
	_pad      int32
}

type gameLobbyJoinRequested struct {
	FriendID sw.CSteamID
	LobbyID  sw.CSteamID
}

var (
	manualRunFrame uintptr
	manualGetNext  uintptr
	manualFreeLast uintptr
	steamPipe      int32
	encoderMu      sync.Mutex
)

func setupManualDispatch() error {
	initPtr, err := sw.LookupSymbol("SteamAPI_ManualDispatch_Init")
	if err != nil {
		return err
	}
	manualRunFrame, err = sw.LookupSymbol("SteamAPI_ManualDispatch_RunFrame")
	if err != nil {
		return err
	}
	manualGetNext, err = sw.LookupSymbol("SteamAPI_ManualDispatch_GetNextCallback")
	if err != nil {
		return err
	}
	manualFreeLast, err = sw.LookupSymbol("SteamAPI_ManualDispatch_FreeLastCallback")
	if err != nil {
		return err
	}
	pipePtr, err := sw.LookupSymbol("SteamAPI_GetHSteamPipe")
	if err != nil {
		return err
	}
	sw.CallSymbolPtr(initPtr)
	steamPipe = int32(sw.CallSymbolPtr(pipePtr))
	if steamPipe == 0 {
		return errors.New("Steam returned an invalid callback pipe")
	}
	return nil
}

func pumpSteam() {
	if steamPipe == 0 {
		return
	}
	sw.CallSymbolPtr(manualRunFrame, uintptr(steamPipe))
	for {
		var message callbackMessage
		if sw.CallSymbolPtr(manualGetNext, uintptr(steamPipe), uintptr(unsafe.Pointer(&message))) == 0 {
			return
		}
		if message.Param != 0 {
			switch message.Callback {
			case gameLobbyJoinRequestedID:
				invite := *(*gameLobbyJoinRequested)(unsafe.Pointer(message.Param))
				sendPush("invite_received", map[string]any{
					"friend_steam_id": fmt.Sprint(uint64(invite.FriendID)),
					"lobby_id":        fmt.Sprint(uint64(invite.LobbyID)),
				})
			case int32(sw.CallbackIDSteamNetConnectionStatusChanged):
				status := *(*sw.SteamNetConnectionStatusChangedCallback_t)(unsafe.Pointer(message.Param))
				onConnectionStatus(status)
			}
		}
		sw.CallSymbolPtr(manualFreeLast, uintptr(steamPipe))
	}
}

func sendPush(command string, data any) {
	encoderMu.Lock()
	defer encoderMu.Unlock()
	if controlEncoder != nil {
		_ = controlEncoder.Encode(response{Command: command, OK: true, Data: data})
	}
}

// Keep encoding through one lock so asynchronous push events can never splice
// bytes into a normal command response.
func encodeResponse(encoder *json.Encoder, value response) error {
	encoderMu.Lock()
	defer encoderMu.Unlock()
	return encoder.Encode(value)
}
