# ROS 2 step-ca Security Bootstrap

Secures a ROS 2 system with **SROS2** (DDS-Security) and certificates from an external
**[step-ca](https://smallstep.com/docs/step-ca/)**. The script

1. finds the running ROS 2 nodes and creates one **enclave** per node (existing enclaves are skipped,
   so you can simply run it again when nodes are added),
2. gets the identity certificate of every new enclave from **step-ca**,
3. generates **least-privilege permissions** from the running graph and signs them,
4. installs **`sros2_renew.sh`**, **`sros2-renew.service`** (`User=$USER`) and **`sros2-renew.timer`**
   for automatic renewal,
5. sets `ROS_SECURITY_KEYSTORE`, `ROS_SECURITY_ENABLE=true` and `ROS_SECURITY_STRATEGY=Enforce` in `~/.bashrc`.

Copying or synchronising enclaves to other hosts is **not** part of the script: every host runs
it for its own nodes. For many hosts over SSH use
[ssh-ros2-step-ca-security-bootstrap](https://github.com/Michdo93/ssh-ros2-step-ca-security-bootstrap).

---

## Requirements

- **ROS 2** Humble or newer with SROS2 (`sudo apt install ros-$ROS_DISTRO-sros2`), sourced or in
  `/opt/ros/<distro>` (the script sources it itself).
- **RMW: Fast DDS** (`rmw_fastrtps_cpp`, the default in Humble and Jazzy), see [RMW](#rmw-fast-dds-vs-cyclone-dds).
- **step CLI** on this host – e.g. with [step-cli-bootstrap](https://github.com/Michdo93/step-cli-bootstrap).
- A reachable **step-ca** with a **JWK provisioner** (the default `admin` provisioner of `step ca init` is one).
- `openssl`, `python3`, `sudo` (only for the renewal script and the systemd units).
- Run the script as the user that runs the nodes – **not** with `sudo`.

---

## Before you start: CA URL, fingerprint, provisioner

You need four things. All commands work on any host with the step CLI.

**1. CA URL** – the address of the step-ca (`address` in `ca.json`, with a name/IP from its
`dnsNames`):

```bash
# on the CA host
step ca health                       # uses the local context
grep -E '"address"|"dnsNames"' -A3 $(step path)/config/ca.json
```

**2. Root fingerprint** (SHA-256 of `root_ca.crt`):

```bash
# on the CA host
step certificate fingerprint $(step path)/certs/root_ca.crt
```

**3. Provisioner** – list them and pick one with `"type": "JWK"`:

```bash
step ca root root_ca.crt --ca-url https://ca.lab:9000 --fingerprint <fingerprint>
step ca provisioner list --ca-url https://ca.lab:9000 --root root_ca.crt
```

```json
[ { "type": "JWK", "name": "admin@lab", "key": { ... }, "encryptedKey": "..." } ]
```

**4. Provisioner password** – the password given to `step ca init` (or `step ca provisioner add …
--create`). The script asks for it once (or reads it with `--password-file`).

Optional: check everything in one go – this must print a token:

```bash
step ca token test --ca-url https://ca.lab:9000 --root root_ca.crt --provisioner admin@lab
```

**Certificate lifetime:** step-ca issues 24 h certificates by default. The timer renews them
after 2/3 of the lifetime (it checks hourly). A certificate that has expired (host switched off
longer than the lifetime) cannot be renewed – run the script again with `--reissue`. For longer
lifetimes raise `maxTLSCertDuration` of the provisioner (`claims` in `ca.json`) and pass
`--not-after 720h`.

---

## Run

1. Start **all nodes of this host without security**, e.g. in a second terminal:

   ```bash
   ROS_SECURITY_ENABLE=false ros2 launch my_robot bringup.launch.py
   ```

2. Run the script:

   ```bash
   wget -qO- https://raw.githubusercontent.com/Michdo93/ros2-step-ca-security-bootstrap/main/setup_sros2.sh | bash
   # or from a clone
   ./setup_sros2.sh --ca-url https://ca.lab:9000 --fingerprint <fingerprint> --provisioner admin@lab
   ```

   It asks for the missing values and the provisioner password, then:

   ```
   Press Enter when all nodes are running...
   Running nodes (the whole ROS domain - nodes of other hosts are visible, too):
       /listener
       /talker
   Do ALL these nodes run on THIS host? (no: choose per node) [Default: yes]:
   [INFO] Generating a policy from the running graph (~/ros2_policies/graph-....policy.xml)...
   [INFO] Enclave /listener: requesting certificate from step-ca...
   [INFO] Enclave /listener: permissions from ~/ros2_policies/listener.policy.xml
   [INFO] Enclave /talker: requesting certificate from step-ca...
   ...
   [INFO] sros2-renew.service (User=michael) and sros2-renew.timer installed and enabled.
   ```

   `ros2 node list` shows the whole ROS domain. If nodes of other hosts are visible, answer
   *no* and select only the nodes of this host.

3. Start every node **with its enclave**. `ROS_SECURITY_ENCLAVE_OVERRIDE` sets one enclave for all
   nodes of a process, so set it per node instead – in the launch file:

   ```python
   Node(package='demo_nodes_cpp', executable='talker', name='talker',
        arguments=['--ros-args', '--enclave', '/talker'])
   ```

   or `ros2 run demo_nodes_cpp talker --ros-args --enclave /talker`. Open a new shell first
   (or `source ~/.bashrc`) so that the `ROS_SECURITY_*` variables are set. Processes that do not
   read `~/.bashrc` (systemd services, cron) need these variables set themselves.

4. The `ros2` command-line tools need an enclave, too (`/ros2cli` is created for them):

   ```bash
   ROS_SECURITY_ENCLAVE_OVERRIDE=/ros2cli ros2 topic list --no-daemon
   ROS_SECURITY_ENCLAVE_OVERRIDE=/ros2cli ros2 topic echo /chatter --no-daemon
   ```

New nodes later: start them (without security), run the script again – only the new nodes get
enclaves, the renewal list is updated.

---

## Options

| Option | Default | Meaning |
|---|---|---|
| `--ca-url URL` | asked | step-ca URL |
| `--fingerprint FP` | asked | root fingerprint; the root is downloaded with `step ca root` and verified |
| `--root FILE` | – | use an existing `root_ca.crt` (checked against `--fingerprint` if given) |
| `--provisioner NAME` | asked | JWK provisioner |
| `--password-file FILE` | asked | provisioner password |
| `--not-after DURATION` | provisioner default (24 h) | certificate lifetime, e.g. `720h` |
| `--keystore DIR` | `~/ros2_keystore` | SROS2 keystore |
| `--policy-dir DIR` | `~/ros2_policies` | generated policies |
| `--enclaves LIST` | running nodes | e.g. `/talker,/ns/listener` (no discovery, no questions) |
| `--permissions graph\|permissive` | `graph` | least privilege from the graph, or everything allowed within the domain |
| `--no-cli-enclave` | – | do not create `/ros2cli` |
| `--permissions-ca-cert FILE` / `--permissions-ca-key FILE` | – | shared permissions CA ([multi-host](#several-hosts)) |
| `--refresh-permissions` | – | re-create the permissions of existing enclaves too |
| `--reissue` | – | new certificates for existing enclaves too (e.g. after expiry) |
| `--no-bashrc` / `--no-timer` | – | skip `~/.bashrc` / renewal installation |
| `--yes` | – | no questions (all values as options, `--enclaves` and `--password-file` required) |

Non-interactive example:

```bash
./setup_sros2.sh --ca-url https://ca.lab:9000 --fingerprint <fp> --provisioner admin@lab \
  --password-file ~/.step-provisioner.pw --enclaves /talker,/listener --permissions permissive --yes
```

---

## What ends up where

```
~/ros2_keystore/                      ROS_SECURITY_KEYSTORE
├── step_root_ca.crt                  root of the step-ca (fingerprint verified)
├── public/
│   ├── ca.cert.pem                   local SROS2 CA (created by ros2 security create_keystore)
│   ├── identity_ca.cert.pem          step-ca intermediate + root  -> verifies the node identities
│   └── permissions_ca.cert.pem       CA that signs governance and permissions
├── private/                          mode 700, keys mode 600
│   └── permissions_ca.key.pem
└── enclaves/
    ├── governance.xml / .p7s
    ├── talker/
    │   ├── cert.pem / key.pem        from step-ca, subject CN=/talker
    │   ├── permissions.xml / .p7s    from ~/ros2_policies/talker.policy.xml
    │   └── identity_ca.cert.pem, permissions_ca.cert.pem, governance.p7s  -> symlinks
    ├── listener/ ...
    └── ros2cli/                      for the ros2 command-line tools (permissive)
~/ros2_policies/                      policies: graph-<date>.policy.xml + one per enclave
/usr/local/bin/sros2_renew.sh         list of all step-ca enclaves, renews each one when due
/etc/systemd/system/sros2-renew.service   Type=oneshot, User=<your user>
/etc/systemd/system/sros2-renew.timer     hourly (+5 min after boot), Persistent=true
```

Check the renewal: `systemctl list-timers sros2-renew.timer`, `sudo systemctl start sros2-renew.service`,
`journalctl -u sros2-renew.service`.

### Policies

The policy path is chosen by the script: `ros2 security generate_policy` writes the policy of the
running graph to `~/ros2_policies/graph-<date>.policy.xml`; from it the script cuts one policy per
enclave (`~/ros2_policies/<enclave>.policy.xml`) and signs it with `ros2 security create_permission`.
A node may then only publish/subscribe/call what it did while the graph was recorded – e.g. a
talker that tries to publish another topic gets `topic not found in allow rule`.
If a node uses more later (e.g. a service that was not called during discovery), edit its policy
and run the script with `--refresh-permissions` (or use `--permissions permissive`).

---

## Several hosts

- **Identities** need nothing extra: every host trusts the same step-ca (`identity_ca.cert.pem`).
- **Permissions** are signed by the permissions CA, and DDS accepts only permissions signed directly
  by a certificate in `permissions_ca.cert.pem`. With a separate permissions CA per host, nodes on
  different hosts reject each other (`Error validating remote permissions`). Use **one shared
  permissions CA**:

  ```bash
  # once, anywhere
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=SROS2 Permissions CA" -keyout permissions_ca.key.pem -out permissions_ca.cert.pem
  # on every host
  ./setup_sros2.sh ... --permissions-ca-cert permissions_ca.cert.pem --permissions-ca-key permissions_ca.key.pem
  ```

  The script imports it, re-signs the governance and the permissions of all enclaves.
  [ssh-ros2-step-ca-security-bootstrap](https://github.com/Michdo93/ssh-ros2-step-ca-security-bootstrap)
  creates and distributes it automatically.
- All hosts need the same `ROS_DOMAIN_ID` as during the setup (it is part of the permissions).
- A firewall must allow DDS: [ufw-bootstrap-kit](https://github.com/Michdo93/ufw-bootstrap-kit)
  does that when the nodes run.

---

## RMW: Fast DDS vs. Cyclone DDS

step-ca signs leaf certificates with its **intermediate** CA. Fast DDS loads all certificates of
`identity_ca.cert.pem` (intermediate + root) and verifies the chain – this works.
Cyclone DDS (0.10, Humble) only supports a **self-signed** identity CA that signs the node
certificates directly ("Verification against a certificate chain is not yet supported" in its
source); nodes fail with `unable to get issuer certificate`. Use Fast DDS
(`export RMW_IMPLEMENTATION=rmw_fastrtps_cpp`).

---

## Notes on the original design

- The variable that ROS 2 reads is **`ROS_SECURITY_KEYSTORE`** (`ROS_SECURITY_KEYSTORE_DIRECTORY`
  is not evaluated by rcl).
- The step-ca root does **not** go to `ca.cert.pem`: `ca.cert.pem` is the local CA whose key
  signs governance and permissions – step-ca never hands out its key. The step-ca chain goes to
  `public/identity_ca.cert.pem`, which the enclaves link to.
- ROS 2 uses `ros2 node list` (`rosnode list` is ROS 1).
- Enclaves live in `<keystore>/enclaves/<name>` (Humble and newer).
- `step ca renew` needs its flags **before** the certificate and key file.
- Neither `ROS_SECURITY_ENCLAVE` nor `ROS_SECURITY_ENCLAVE_OVERRIDE` is set globally – the enclave is
  given per node (`--enclave`), as above.

## License

MIT License. Feel free to use and modify.
