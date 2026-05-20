# Distributed Inferencing Prototype

This repository demonstrates a distributed `iii` worker mesh deployed across three GCP VMs. A Python inference worker exposes `inference::run_inference`, and a TypeScript caller worker exposes an HTTP trigger that forwards requests through the mesh.

| Worker             | Language   | Function                       | Current behavior                                                                                 |
| ------------------ | ---------- | ------------------------------ | --------------------------------------------------------------------------------------------- |
| `inference-worker` | Python     | `inference::run_inference`     | Calls Ollama at `OLLAMA_URL` and returns the raw model output string.                             |
| `caller-worker`    | TypeScript | `inference::get_response`      | Calls `inference::run_inference` and forwards the response payload.                              |
| `caller-worker`    | TypeScript | `http::run_inference_over_http` | HTTP trigger bound to `POST /v1/chat/completions`; forwards the request body to `get_response`.   |

For more details regarding implementation, find docs here: https://iii.dev/docs/

> Note: the current implementation uses Ollama `gemma3:1b` in the Python worker, not `transformers` or `gemma-3-270m`. This README has been updated to match the current code and runtime wiring.



# Alchemyst DevOps Assignment

Distributed deployment of the `iii` worker mesh across three GCP VMs.

## Architecture
Internet
│
▼ POST /v1/chat/completions (port 3111)
┌─────────────────────────────────────────┐
│           PRIVATE VPC (10.0.0.0/24)     │
│                                         │
│  ┌──────────────┐                       │
│  │  engine-vm   │  10.0.0.2 (public IP) │
│  │  iii engine  │  port 3111 + 49134    │
│  └──────┬───────┘                       │
│         │ WebSocket RPC (port 49134)    │
│   ┌─────┴──────┐                        │
│   │            │                        │
│ ┌─▼──────┐  ┌──▼───────┐               │
│ │caller  │  │inference │               │
│ │-vm     │  │-vm       │               │
│ │TypeScr │  │Python +  │               │
│ │10.0.0.3│  │ollama    │               │
│ └────────┘  │10.0.0.4  │               │
│             └──────────┘               │
└─────────────────────────────────────────┘

## Request Flow

1. `curl POST /v1/chat/completions` hits engine-vm:3111
2. iii engine routes to caller-worker (TypeScript, caller-vm)
3. caller-worker calls `inference::run_inference` via RPC
4. inference-worker (Python, inference-vm) calls ollama locally
5. ollama runs gemma3:1b and returns the response back up the chain

## Network Hygiene

- Only engine-vm has a public IP (tagged `api-gateway`)
- caller-vm and inference-vm have no public IP — unreachable from internet
- Private VMs reach the internet via Cloud NAT for package installs only
- Internal communication happens over the private subnet (10.0.0.0/24)

## Deploy with Terraform

```bash
cd terraform
terraform init
terraform apply
```

## Test

```bash
curl -X POST http://<engine-public-ip>:3111/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "What is 2 + 2?"}]}'
```

Expected response:
```json
{"result": {"0":"2","1":" ","2":"+","3":" ","4":"2","5":" ","6":"=","7":" ","8":"4"}}
```

## VM Setup (manual steps after Terraform)

### engine-vm
```bash
curl -fsSL https://iii.dev/install.sh | sh
git clone https://github.com/pror993/alchemyst-devops-assignment.git
cd alchemyst-devops-assignment
nohup iii --config config.yaml > ~/iii-engine.log 2>&1 &
```

### caller-vm
```bash
git clone https://github.com/pror993/alchemyst-devops-assignment.git
cd alchemyst-devops-assignment/workers/caller-worker
npm install
III_URL=ws://10.0.0.2:49134 nohup npx tsx src/worker.ts > ~/caller-worker.log 2>&1 &
```

### inference-vm
```bash
git clone https://github.com/pror993/alchemyst-devops-assignment.git
cd alchemyst-devops-assignment/workers/inference-worker
pip3 install -r requirements.txt
curl -fsSL https://ollama.com/install.sh | sh
ollama pull gemma3:1b
ollama serve &
III_URL=ws://10.0.0.2:49134 nohup python3 inference_worker.py > ~/inference-worker.log 2>&1 &
```