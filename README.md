# ⚙️ InfraPilot

AI-driven infrastructure orchestration system for VPS fleets using SSH + LLM reasoning (NVIDIA NIM / Step 3.5 Flash).

It observes servers, reasons about issues, and safely executes changes across single or multi-node environments.

---

## 🧠 Features

- SSH-based multi-VPS orchestration
- AI decision layer (Step 3.5 Flash via NVIDIA NIM)
- Multi-node swarm support
- Superagent beta mode (multi-agent reasoning system)
- Safety validation + service allowlists
- Snapshot-based rollback system
- Explain-only mode (`--why`)

---

## 🚀 Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/solarnode-developement/Infrapilot/refs/heads/main/launch.sh | bash
```

---

## ⚙️ Setup

### 1. Set API key
```bash
export NIM_API_KEY="your_key_here"
```

### 2. Configure SSH nodes inside `launch.sh`
```bash
NODES=(
  "root@vps1"
  "root@vps2"
)
```

### 3. Ensure SSH access
```bash
ssh-copy-id root@vps1
```

---

## ▶️ Usage

### Standard swarm mode
```bash
./launch.sh --swarm
```

### Superagent mode (beta)
```bash
./launch.sh --swarm-beta
```

### Explain mode (no changes)
```bash
./launch.sh --why
```

---

## 🧠 Architecture

System flow:

State Collection (SSH Pool)
        ↓
Normalization Layer
        ↓
LLM Reasoning (Step 3.5 Flash)
        ↓
Multi-Agent Superagent (optional)
        ↓
Safety Validation Layer
        ↓
Snapshot System
        ↓
Execution Engine (SSH swarm)

---

## 🤖 Superagents

- Auditor → finds issues
- Optimizer → improves performance
- Ops → practical fixes
- Safety → blocks dangerous actions
- Orchestrator → merges final plan

---

## 🧯 Safety

InfraPilot enforces:

- Allowlisted services only (nginx, docker, redis)
- JSON schema validation
- Execution filtering
- Snapshot creation before changes
- Explain-only diagnostic mode

---

## 📸 Rollback

Snapshots are created before execution.

Rollback restores previous cluster state (partial implementation, extendable per deployment).

---

## ⚠️ Warning

This tool can modify multiple servers via SSH.

Do NOT run on:
- production systems without review
- systems without SSH key control
- anything you care about more than curiosity

---

## 🧠 Philosophy

InfraPilot treats infrastructure as a system that can be:
- observed
- reasoned about
- safely modified via structured AI decisions

Not a pile of scripts pretending to be DevOps.
