# KillBridgeTCP Widget

A Lua widget for **Beyond All Reason** that creates a TCP network bridge to stream real-time game events and statistics to external applications.

## Overview

KillBridgeTCP enables communication between a Beyond All Reason game client and external applications via TCP sockets. It captures in-game events (unit kills, damage, construction) and team statistics (resource management, combat metrics) and sends them as JSON over a TCP connection.

## Features

- **Real-time event streaming** via TCP to localhost:5005
- **JSON-formatted messages** for easy parsing
- **Automatic reconnection** with 5-second intervals
- **Event tracking** including:
  - Unit construction completion
  - Unit damage taken
  - Unit destruction (with attacker information)
  - Game initialization and start events
- **Team statistics** updated every 10 game seconds:
  - Resource income, usage, storage, and transfers (metal & energy)
  - Combat metrics (damage dealt/received, units killed/died)
  - Unit captures and exchanges
- **Player and team identification** automatically enriched into all messages

## Installation

1. Place the widget file in your Beyond All Reason widgets directory
2. Enable it in-game via the widgets menu (or it will be enabled by default)
3. Ensure a TCP listener is running on `127.0.0.1:5005` to receive messages

## TCP Listener

Designed to work best with https://github.com/bobmitch/bar_relay BAR Relay

## TCP Connection

The widget communicates with:
- **Host:** 127.0.0.1 (localhost)
- **Port:** 5005
- **Protocol:** TCP, non-blocking sockets
- **Message Format:** JSON, newline-delimited

**Message Structure:**  
Each message is a JSON object followed by a newline character (`\n`). This allows receivers to parse streaming messages line-by-line.

```json
{"event":"GameStart","playerName":"Player1","allyTeamID":0,"myPlayerID":0,"myTeamID":0,"gameTime":0}
```

## Events

### Initialization Events

#### WidgetInitializedPreGame
Sent when the widget initializes before the game starts.

```json
{
  "event": "WidgetInitializedPreGame",
  "playerName": "YourName",
  "allyTeamID": 0,
  "myPlayerID": 0,
  "myTeamID": 0,
  "gameTime": 0
}
```

#### WidgetInitializedMidGame
Sent when the widget is toggled on or started after the game has already begun.

```json
{
  "event": "WidgetInitializedMidGame",
  "playerName": "YourName",
  "allyTeamID": 0,
  "myPlayerID": 0,
  "myTeamID": 0,
  "gameTime": 15
}
```

#### GameStart
Sent when the game officially starts.

```json
{
  "event": "GameStart",
  "playerName": "YourName",
  "allyTeamID": 0,
  "myPlayerID": 0,
  "myTeamID": 0,
  "gameTime": 0
}
```

### Unit Events

#### UnitFinished
Sent when a unit is constructed and becomes active. Tracks units from all sides (self, ally, enemy).

```json
{
  "event": "UnitFinished",
  "relation": "self",
  "unitName": "armcom",
  "unitID": 1,
  "unitTeam": 0,
  "unitTier": "1",
  "unitCategory": ["VEHICLE", "MOBILE"],
  "unitMetalCost": 1500,
  "playerName": "YourName",
  "allyTeamID": 0,
  "myPlayerID": 0,
  "myTeamID": 0,
  "gameTime": 45
}
```

**Relation values:**
- `"self"` — Unit belongs to your team
- `"ally"` — Unit belongs to an allied team
- `"enemy"` — Unit belongs to an enemy team

#### UnitDamaged
Sent when your team's units take damage. **Note:** Only damage to your own units is tracked due to line-of-sight visibility limitations.

```json
{
  "event": "UnitDamaged",
  "unitID": 1,
  "unitDefID": 3,
  "unitTeam": 0,
  "damage": 45.5,
  "paralyzer": 0,
  "weaponDefID": 5,
  "projectileID": 10,
  "attackerID": 25,
  "attackerDefID": 4,
  "attackerTeam": 1,
  "playerName": "YourName",
  "allyTeamID": 0,
  "myPlayerID": 0,
  "myTeamID": 0,
  "gameTime": 120
}
```

#### UnitDestroyed
Sent when any unit is destroyed. Only triggers if the destroyed unit or the attacking unit belongs to your team (line-of-sight restriction).

```json
{
  "event": "UnitDestroyed",
  "myAllyTeamID": 0,
  "unitAllyTeamID": 0,
  "attackerAllyTeamID": 1,
  "unitID": 1,
  "unitDefID": 3,
  "unitName": "armsolar",
  "unitMetalCost": 45,
  "unitCategory": ["BUILDING"],
  "unitTier": "1",
  "unitTeam": 0,
  "victimPlayer": "YourName",
  "attackerID": 25,
  "attackerDefID": 4,
  "attackerName": "armpw",
  "attackerTeam": 1,
  "attackerPlayer": "Enemy",
  "attackerMetalCost": 160,
  "attackerCategory": ["VEHICLE", "MOBILE"],
  "attackerTier": "1",
  "attackerCumulativeDamage": 1250,
  "playerName": "YourName",
  "allyTeamID": 0,
  "myPlayerID": 0,
  "myTeamID": 0,
  "gameTime": 240
}
```

### Statistics Events

#### FullStatsUpdate
Sent every 10 seconds (300 game frames) with comprehensive team statistics.

```json
{
  "event": "FullStatsUpdate",
  "frame": 300,
  "metal": {
    "income": 2.5,
    "usage": 1.8,
    "storage": 500,
    "pull": 0.2,
    "share": 0,
    "sent": 0,
    "received": 0,
    "excess": 0.7
  },
  "energy": {
    "income": 8.5,
    "usage": 7.2,
    "storage": 1000,
    "pull": 0.3,
    "share": 0,
    "sent": 0,
    "received": 0,
    "excess": 1.3
  },
  "combat": {
    "damage_dealt": 250,
    "damage_received": 120,
    "units_killed": 3,
    "units_died": 1,
    "units_captured": 0,
    "units_lost": 0,
    "units_received": 0,
    "units_sent": 0
  },
  "playerName": "YourName",
  "allyTeamID": 0,
  "myPlayerID": 0,
  "myTeamID": 0,
  "gameTime": 300
}
```

## Message Enrichment

All messages automatically include the following fields:

- `playerName` — Your player's name
- `allyTeamID` — Your alliance team ID
- `myPlayerID` — Your player ID
- `myTeamID` — Your team ID
- `gameTime` — Elapsed game time in seconds

## Implementation Details

### Connection Handling

The widget maintains a persistent TCP connection with automatic reconnection:

- Attempts reconnection every 5 seconds if disconnected
- Non-blocking sockets prevent gameplay freezes
- Graceful handling of timeouts and connection failures

### Data Enrichment

Event data is enriched with player and team context before sending:

```lua
local myPlayerID = Spring.GetMyPlayerID()
local name, _, _, _, allyTeamID = Spring.GetPlayerInfo(myPlayerID)
local myTeamID = Spring.GetMyTeamID()
```

### JSON Encoding

Uses the included `json.lua` utility for reliable encoding of Lua tables to JSON.

## Dependencies

- **Lua 5.1+** (provided by Beyond All Reason)
- **LuaSocket** (standard in BAR)
- **json.lua** utility (`common/luaUtilities/json.lua`)

## Limitations

- **Damage tracking:** Only damage to your own units is reported due to line-of-sight visibility constraints
- **Unit tracking:** `UnitDestroyed` only fires if you own the destroyed unit or the attacking unit
- **Network:** Only connects to localhost (127.0.0.1:5005)
- **Non-blocking:** Sockets are non-blocking; high-frequency events may be dropped on network congestion

## Configuration

To modify connection parameters, edit these constants at the top of the widget:

```lua
local RECONNECT_INTERVAL = 5  -- seconds between reconnection attempts
```

To change the TCP endpoint:

```lua
local success, err = client:connect("127.0.0.1", 5005)
```

## Troubleshooting

**No connection established**
- Verify a TCP listener is running on `127.0.0.1:5005`
- Check the game console for error messages (`Spring.Echo` output)
- Confirm the widget is enabled in the widgets menu

**Events not being received**
- Verify the TCP receiver is accepting and reading data
- Check that JSON parsing is working correctly in your receiver
- Ensure messages are being read line-by-line (newline-delimited)

**Connection drops**
- The widget will automatically attempt to reconnect
- Check firewall or network settings
- Verify the receiver is still listening on the expected port

## Receiver Implementation Example

A simple Python example to receive and parse messages:

```python
import socket
import json

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 5005))
sock.listen(1)

conn, addr = sock.accept()
print(f"Connected by {addr}")

while True:
    data = conn.recv(1024).decode('utf-8')
    if not data:
        break
    
    for line in data.strip().split('\n'):
        if line:
            message = json.loads(line)
            print(message)

conn.close()
```

## License

MIT

## Support

Raise issues here
