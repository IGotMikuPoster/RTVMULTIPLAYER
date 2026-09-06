// SPDX-License-Identifier: MIT
package main

import (
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"time"
	"unsafe"

	sw "github.com/plaught-armor/go-steamworks"
)

type udpTunnel struct {
	connection sw.HSteamNetConnection
	socket     *net.UDPConn
	done       chan struct{}
	closeOnce  sync.Once
	mu         sync.RWMutex
	clientAddr *net.UDPAddr
}

type outboundPacket struct {
	connection sw.HSteamNetConnection
	data       []byte
}

var (
	listenSocket sw.HSteamListenSocket
	pollGroup    sw.HSteamNetPollGroup
	clientConn   sw.HSteamNetConnection
	clientState  sw.ESteamNetworkingConnectionState
	enetServer   *net.UDPAddr
	hostTunnels  = map[sw.HSteamNetConnection]*udpTunnel{}
	clientSide   *udpTunnel
	outbound     = make(chan outboundPacket, 512)
	tunnelMu     sync.RWMutex
)

func startP2PHost(port int) (map[string]any, error) {
	stopP2P()
	ns := sw.SteamNetworkingSockets()
	listenSocket = ns.CreateListenSocketP2P(0, nil)
	if listenSocket == 0 {
		return nil, errors.New("Steam could not create P2P listen socket")
	}
	pollGroup = ns.CreatePollGroup()
	if pollGroup == 0 {
		ns.CloseListenSocket(listenSocket)
		listenSocket = 0
		return nil, errors.New("Steam could not create P2P poll group")
	}
	enetServer = &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: port}
	return map[string]any{"listen": true, "virtual_port": 0, "enet_port": port}, nil
}

func startP2PClient(host sw.CSteamID) (map[string]any, error) {
	stopP2P()
	var identity sw.SteamNetworkingIdentity
	identity.SetSteamID(host)
	clientState = sw.ESteamNetworkingConnectionState_None
	clientConn = sw.SteamNetworkingSockets().ConnectP2P(&identity, 0, nil)
	if clientConn == 0 {
		return nil, errors.New("Steam could not begin P2P connection")
	}
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		return nil, fmt.Errorf("local UDP tunnel: %w", err)
	}
	clientSide = &udpTunnel{connection: clientConn, socket: socket, done: make(chan struct{})}
	go relayUDP(clientSide)
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		pumpSteam()
		tickTunnel()
		if clientState == sw.ESteamNetworkingConnectionState_Connected {
			return map[string]any{"tunnel_port": socket.LocalAddr().(*net.UDPAddr).Port}, nil
		}
		if clientState == sw.ESteamNetworkingConnectionState_ClosedByPeer || clientState == sw.ESteamNetworkingConnectionState_ProblemDetectedLocally {
			stopP2P()
			return nil, errors.New("Steam P2P connection was rejected")
		}
		time.Sleep(20 * time.Millisecond)
	}
	stopP2P()
	return nil, errors.New("Steam P2P connection timed out")
}

func onConnectionStatus(status sw.SteamNetConnectionStatusChangedCallback_t) {
	state := status.Info.State
	if status.Conn == clientConn {
		clientState = state
	}
	if status.Info.ListenSocket == listenSocket && state == sw.ESteamNetworkingConnectionState_Connecting {
		ns := sw.SteamNetworkingSockets()
		if ns.AcceptConnection(status.Conn) != sw.EResultOK || !ns.SetConnectionPollGroup(status.Conn, pollGroup) {
			return
		}
		socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
		if err != nil {
			return
		}
		tunnel := &udpTunnel{connection: status.Conn, socket: socket, done: make(chan struct{})}
		tunnelMu.Lock()
		hostTunnels[status.Conn] = tunnel
		tunnelMu.Unlock()
		go relayUDP(tunnel)
		log.Printf("accepted Steam P2P connection %d", status.Conn)
	}
	if state == sw.ESteamNetworkingConnectionState_ClosedByPeer || state == sw.ESteamNetworkingConnectionState_ProblemDetectedLocally {
		closeTunnel(status.Conn)
	}
}

func tickTunnel() {
	ns := sw.SteamNetworkingSockets()
	for i := 0; i < 128; i++ {
		select {
		case packet := <-outbound:
			_, _ = ns.SendMessageToConnection(packet.connection, packet.data, sw.SteamNetworkingSend_Unreliable|sw.SteamNetworkingSend_NoNagle)
		default:
			i = 128
		}
	}
	if pollGroup != 0 {
		for _, message := range ns.ReceiveMessagesOnPollGroup(pollGroup, 64) {
			data := copySteamMessage(message)
			tunnelMu.RLock()
			tunnel := hostTunnels[message.Connection]
			tunnelMu.RUnlock()
			if tunnel != nil && enetServer != nil && len(data) > 0 {
				_, _ = tunnel.socket.WriteToUDP(data, enetServer)
			}
			message.Release()
		}
	}
	if clientConn != 0 && clientSide != nil {
		for _, message := range ns.ReceiveMessagesOnConnection(clientConn, 64) {
			data := copySteamMessage(message)
			clientSide.mu.RLock()
			address := clientSide.clientAddr
			clientSide.mu.RUnlock()
			if address != nil && len(data) > 0 {
				_, _ = clientSide.socket.WriteToUDP(data, address)
			}
			message.Release()
		}
	}
}

func relayUDP(tunnel *udpTunnel) {
	buffer := make([]byte, 65535)
	for {
		_ = tunnel.socket.SetReadDeadline(time.Now().Add(250 * time.Millisecond))
		count, address, err := tunnel.socket.ReadFromUDP(buffer)
		if err != nil {
			select {
			case <-tunnel.done:
				return
			default:
			}
			if temporary, ok := err.(net.Error); ok && temporary.Timeout() {
				continue
			}
			return
		}
		if tunnel == clientSide {
			tunnel.mu.Lock()
			tunnel.clientAddr = address
			tunnel.mu.Unlock()
		}
		data := append([]byte(nil), buffer[:count]...)
		select {
		case outbound <- outboundPacket{connection: tunnel.connection, data: data}:
		default:
		}
	}
}

func copySteamMessage(message *sw.SteamNetworkingMessage) []byte {
	if message == nil || message.Data == 0 || message.Size <= 0 || message.Size > 65535 {
		return nil
	}
	return append([]byte(nil), unsafe.Slice((*byte)(unsafe.Pointer(message.Data)), int(message.Size))...)
}

func closeTunnel(connection sw.HSteamNetConnection) {
	tunnelMu.Lock()
	tunnel := hostTunnels[connection]
	delete(hostTunnels, connection)
	tunnelMu.Unlock()
	if tunnel != nil {
		tunnel.close()
	}
	if connection == clientConn && clientSide != nil {
		clientSide.close()
		clientSide = nil
		clientConn = 0
	}
}

func (t *udpTunnel) close() {
	t.closeOnce.Do(func() { close(t.done); _ = t.socket.Close() })
}

func stopP2P() {
	ns := sw.SteamNetworkingSockets()
	if clientConn != 0 {
		ns.CloseConnection(clientConn, 0, "session closed", false)
	}
	if clientSide != nil {
		clientSide.close()
	}
	clientConn, clientSide = 0, nil
	tunnelMu.Lock()
	for connection, tunnel := range hostTunnels {
		ns.CloseConnection(connection, 0, "session closed", false)
		tunnel.close()
		delete(hostTunnels, connection)
	}
	tunnelMu.Unlock()
	if listenSocket != 0 {
		ns.CloseListenSocket(listenSocket)
	}
	if pollGroup != 0 {
		ns.DestroyPollGroup(pollGroup)
	}
	listenSocket, pollGroup, enetServer = 0, 0, nil
}
