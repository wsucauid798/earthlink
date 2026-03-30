# EarthLink

A Symbolic Virtual World for training artificial agents in cross-world exploration.

EarthLink is a research platform where autonomous intelligent agents learn from real-world data to become possible explorers of other worlds. The system uses human knowledge as a lens for exploring human and non-human realities -- building agents that think with us so they can explore worlds we cannot enter ourselves.

Worlds in EarthLink are strategy spaces with explicit state structures, action constraints, and reward topologies. The current instantiation anchors the SVW to Earth -- real places, real weather, real celestial mechanics, real civilisation data proxied live from the internet. Future worlds are created by ingesting new data: Mars terrain, abstract environments, synthetic rule systems.

## Research Context

This system is supported by two published papers:

- **"Indirect Utility Maximization via Second-Order Agents"** (MMVE'26, Hong Kong) -- formalises cross-world exploration and proposes second-order agents as strategic proxies for extending human agency into inaccessible worlds.
- **"A Symbolic Virtual World for Training Agents in Cross-World Exploration"** -- introduces the SVW concept, reports initial empirical results confirming measurable sensitivity to regime variation.

## Components

| Repository | Description |
|---|---|
| [earthlink-server](earthlink-server/) | Python backend -- SVW engine, world simulation, agent execution, Earth-proxy layer, REST API, WebSocket streaming |
| [earthlink-desktop](earthlink-desktop/) | Tauri + React desktop app -- real-time map visualisation, agent tracking, world inspection, simulation control |
| [earthlink-web](earthlink-web/) | React web client -- browser-based viewer for the simulation |
| [earthlink-mobile](earthlink-mobile/) | React Native mobile app -- monitoring and control companion |
| [earthlink-cli](earthlink-cli/) | Command-line interface -- terminal access to the world and agents |
| [earthlink-website](earthlink-website/) | Showcase website |

## Architecture

```
                    +-----------------+
                    |  EarthLink SVW  |
                    |    (Server)     |
                    +--------+--------+
                             |
              REST API + WebSocket Streaming
                             |
         +-------------------+-------------------+
         |         |         |         |         |
      Desktop    Web      Mobile     CLI     Website
      (Tauri)  (React)  (React    (Node)   (Next.js)
               Native)
```

The server hosts the Symbolic Virtual World -- world state, agent execution, Earth-proxy evidence access, and instrumentation. All frontends are viewers and controllers. All world truth lives on the server.

## Quick Start

```bash
# Start the server (Docker)
cd earthlink-server
docker compose up --build -d

# Start the desktop app
cd earthlink-desktop
npm install
npx tauri dev

# Or use the CLI
cd earthlink-cli
./earthlink world state
```

## Author

William Sawyerr

## License

[MIT](LICENSE)
