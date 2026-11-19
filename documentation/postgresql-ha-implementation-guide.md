# PostgreSQL High Availability (HA) – Implementation Notes

## 1. What this project does

This project runs a small PostgreSQL High Availability cluster using Docker Compose.

It contains two PostgreSQL servers:

- `ha-postgres-1`
- `ha-postgres-2`

The cluster uses three supporting components:

| Component | Responsibility |
|---|---|
| PostgreSQL | Stores the database and replicates changes from the primary to the replica |
| Patroni | Monitors PostgreSQL nodes and manages promotion, failover and recovery |
| etcd | Stores shared cluster coordination information, including the leader lock |
| HAProxy | Gives applications one connection endpoint and routes new connections to the current primary |

The application connects to HAProxy on port `5000`. HAProxy checks Patroni to identify the current primary and routes the database connection to that node.

**Important:** Patroni does not copy table data. PostgreSQL streaming replication does that. etcd does not store database rows or WAL files. HAProxy does not replicate or commit data.

## 2. Architecture

```text
                 Application / psql client
                           |
                           | PostgreSQL connection
                           | ha-haproxy:5000
                           v
                        HAProxy
                           |
              checks Patroni REST API (:8008)
                           |
              +------------+------------+
              |                         |
              v                         v
       ha-postgres-1              ha-postgres-2
       PostgreSQL                 PostgreSQL
       Patroni                    Patroni
       Primary                    Replica
              |                         ^
              |---- WAL streaming ------|
              |
       Patroni instances
              |
              v
             etcd
      Shared cluster state
```

The primary/replica roles can switch after a failure. The names `ha-postgres-1` and `ha-postgres-2` do not permanently determine which node is primary.

## 3. Prerequisites

On the Windows machine:

- Docker Desktop installed and running.
- Docker Compose available through `docker compose`.
- PowerShell.
- The project files, including the Compose file and the Patroni and HAProxy configuration files.

Open PowerShell and move to the project directory:

```powershell
cd "high-availability-pgs"
```

Check Docker:

```powershell
docker version
docker compose version
docker info
```

If `docker info` fails, start Docker Desktop before continuing.

## 4. How the two PostgreSQL servers are created

Docker Compose starts the containers defined in the project's Compose file. The two PostgreSQL containers are separate database server instances, even though they run on the same Docker host.

The Compose configuration should define:

- Two PostgreSQL/Patroni services.
- A separate Patroni configuration for each node.
- Persistent storage for each PostgreSQL data directory.
- An etcd service or services used as Patroni's Distributed Configuration Store (DCS).
- An HAProxy service.
- A shared Docker network so the containers can reach one another by service/container name.

The project uses these node names:

```text
ha-postgres-1
ha-postgres-2
```

The Patroni configuration files used by the project are:

```text
/etc/patroni/patroni1.yml
/etc/patroni/patroni2.yml
```

The two Patroni configurations must use the same cluster scope, but each node must have its own unique Patroni member name and PostgreSQL connection addresses.

### Start the containers

From the project directory:

```powershell
docker compose up -d
```

List the containers:

```powershell
docker compose ps
```

List all running Docker containers:

```powershell
docker ps
```

View the Compose service logs:

```powershell
docker compose logs
```

Follow logs continuously:

```powershell
docker compose logs -f
```

To inspect one container:

```powershell
docker logs ha-postgres-1
docker logs ha-postgres-2
docker logs ha-haproxy
```

Use `Ctrl+C` to stop following logs. This does not stop the containers.

## 5. How primary and replica are connected

The two PostgreSQL nodes are not configured as two independent databases. Patroni manages them as members of the same cluster.

At initial bootstrap, Patroni initializes the cluster and establishes the first primary. The other node joins as a replica.

The primary accepts writes. PostgreSQL records database changes in its Write-Ahead Log (WAL). The replica receives and replays WAL records through PostgreSQL streaming replication.

A simplified flow is:

1. An application sends a write query to the primary.
2. PostgreSQL changes the data and writes the corresponding WAL records.
3. The replica receives WAL records from the primary.
4. The replica replays those records to keep its data up to date.

Patroni monitors both nodes and coordinates their roles. It uses etcd to coordinate which node holds the leader lock.

### Check the cluster role

Run `patronictl` from either PostgreSQL container:

```powershell
docker exec ha-postgres-1 patronictl -c /etc/patroni/patroni1.yml list
```

Or:

```powershell
docker exec ha-postgres-2 patronictl -c /etc/patroni/patroni2.yml list
```

The output should show one `Leader` and one `Replica`. The replica should normally show a streaming state when replication is working.

The primary can be either node. Do not assume that `ha-postgres-1` is always the primary.

## 6. What Patroni does

Patroni runs alongside PostgreSQL on each database node.

Its responsibilities are:

- Monitor PostgreSQL health.
- Check whether the node is primary or replica.
- Coordinate leadership through etcd.
- Promote an eligible replica if the primary fails.
- Reconfigure a recovered former primary so it can rejoin as a replica.

The Patroni REST API is available on port `8008` inside the Docker network.

The `/primary` endpoint is used by this project to check whether a node is currently the primary:

```text
http://ha-postgres-1:8008/primary
http://ha-postgres-2:8008/primary
```

A successful primary check indicates that the node is currently serving as the primary according to Patroni.

## 7. What etcd does

etcd is the Distributed Configuration Store (DCS) used by Patroni.

It stores shared coordination information, such as:

- Which node currently holds the leader lock.
- Cluster configuration information.
- Membership and coordination state used by Patroni.

Patroni instances use this shared state to coordinate leadership and avoid independently treating different nodes as primary.

etcd does **not** store PostgreSQL tables, rows, or replicated WAL data. PostgreSQL handles database replication separately.

For production, etcd should itself be deployed with redundancy. A single etcd member can become a point of failure. A common resilient arrangement is a three-member etcd cluster, which can tolerate one member failure while retaining quorum.

## 8. What HAProxy does

HAProxy is the stable connection endpoint for applications.

In this project, applications connect to:

```text
Host: ha-haproxy
Port: 5000
```

HAProxy checks the Patroni REST API to identify the current primary. It then routes new PostgreSQL connections to that node.

This means the application does not need to know whether `ha-postgres-1` or `ha-postgres-2` is currently primary.

HAProxy does not:

- Promote a replica.
- Copy database data.
- Replicate WAL.
- Move an already-established database session to another server.

After failover, new connections can be routed to the new primary. An existing connection to the failed server is normally broken, so the application must reconnect and retry safely where appropriate.

## 9. Connect to PostgreSQL through HAProxy

The database details used by the project are:

```text
Database: ha_demo
User:     ha_app
Host:     ha-haproxy
Port:     5000
```

A convenient way to run `psql` from PowerShell without installing the PostgreSQL client on Windows is to start a temporary PostgreSQL 17 client container on the project's Docker network.

Replace the password placeholder with the database user's password:

```powershell
docker run --rm -it --network high-availability-pgs_default -e PGPASSWORD="<ha_app-password>" postgres:17 psql -h ha-haproxy -p 5000 -U ha_app -d ha_demo
```

Once connected, check which server answered:

```sql
SELECT inet_server_addr(), pg_is_in_recovery();
```

Interpretation:

- `pg_is_in_recovery() = false`: the connected PostgreSQL node is the primary.
- `pg_is_in_recovery() = true`: the connected PostgreSQL node is a standby/replica.

You can also check the current database:

```sql
SELECT current_database(), current_user;
```

Exit `psql` with:

```text
\q
```

Avoid putting real passwords directly into scripts or committing them to source control. The command above uses a placeholder for clarity.

## 10. Check replication directly

Use `patronictl` to see the cluster roles and replication state:

```powershell
docker exec ha-postgres-1 patronictl -c /etc/patroni/patroni1.yml list
```

The table includes the member, role, state, timeline and WAL positions. A replica in `streaming` state with zero reported lag is a good sign that it has caught up at the time of the check.

You can also connect directly to a node for a read-only role check. For example, from inside a PostgreSQL container:

```powershell
docker exec -it ha-postgres-1 psql -U ha_app -d ha_demo
```

Then run:

```sql
SELECT pg_is_in_recovery();
```

Use the actual database credentials/configuration if local authentication requires them.

## 11. Failover and recovery test

The project includes a PowerShell test script for testing automatic failover and recovery.

The test performs the following steps:

1. Checks that Docker is available and the two PostgreSQL containers and HAProxy are running.
2. Checks both Patroni `/primary` endpoints and confirms that exactly one node is primary.
3. Connects through HAProxy and confirms that it reaches the current primary.
4. Writes a uniquely named test record before failover.
5. Stops the current primary container to simulate a failure.
6. Waits for Patroni to promote the other node.
7. Confirms that HAProxy routes new connections to the promoted primary.
8. Checks that the pre-failover test record is present and writes another record after failover.
9. Restarts the former primary.
10. Waits for the former primary to rejoin as a replica.
11. Checks that the test records are present on the recovered replica and that it is in recovery mode.
12. Prints the final test result.

### Useful commands used by the test

Check whether a container is running:

```powershell
docker inspect -f '{{.State.Running}}' ha-postgres-1
docker inspect -f '{{.State.Running}}' ha-postgres-2
docker inspect -f '{{.State.Running}}' ha-haproxy
```

Get a container's Docker network IP:

```powershell
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ha-postgres-1
```

Stop the current primary to simulate failure:

```powershell
docker stop ha-postgres-1
```

**Only run that command when you have confirmed that `ha-postgres-1` is currently the primary and you intentionally want to test failover.** If `ha-postgres-2` is the primary, use that container name instead.

Restart the stopped node:

```powershell
docker start ha-postgres-1
```

Again, use the name of the node that was stopped.

The test script uses a temporary BusyBox container to call Patroni's REST API from inside the Docker network. It uses a temporary `postgres:17` container to run `psql` through HAProxy.

### Run the automated test

Run the PowerShell test script from the project directory. Use the actual filename of the script in your project:

```powershell
.\<your-ha-test-script>.ps1
```

The script asks for the `ha_app` database password. It should finish with:

```text
RESULT: ALL TESTS PASSED
```

A passing run means the tested failover, HAProxy rerouting, former-primary recovery and replication checks succeeded for that run.

### What the test demonstrated in this implementation

In the successful run recorded for this project:

- `ha-postgres-2` was initially the primary.
- `ha-postgres-1` was initially the replica.
- The primary was stopped.
- Patroni promoted the other node.
- The PostgreSQL timeline advanced from 6 to 7.
- HAProxy began routing new connections to the promoted primary.
- The stopped node was restarted and rejoined as a replica.
- The test records were visible on the recovered replica.
- The recovered node reported `pg_is_in_recovery() = true`.

The roles can be reversed on a later run, so always check the current cluster state first.

## 12. Useful day-to-day PowerShell commands

Run from the project directory unless stated otherwise.

| Task | Command |
|---|---|
| Start the cluster | `docker compose up -d` |
| Show Compose containers | `docker compose ps` |
| Show all running containers | `docker ps` |
| Follow all Compose logs | `docker compose logs -f` |
| Show PostgreSQL 1 logs | `docker logs ha-postgres-1` |
| Show PostgreSQL 2 logs | `docker logs ha-postgres-2` |
| Show HAProxy logs | `docker logs ha-haproxy` |
| Show Patroni cluster state | `docker exec ha-postgres-1 patronictl -c /etc/patroni/patroni1.yml list` |
| Stop one container | `docker stop <container-name>` |
| Start one container | `docker start <container-name>` |
| Stop Compose services | `docker compose stop` |
| Start stopped Compose services | `docker compose start` |

To stop and remove the Compose containers and network while keeping named volumes:

```powershell
docker compose down
```

Do **not** add `-v` unless you intentionally want to delete the Compose-managed volumes. Removing PostgreSQL volumes can permanently delete the database data and may require rebuilding the cluster from scratch.

To validate the Compose file before starting:

```powershell
docker compose config
```

## 13. Important points and limitations

- This is a two-PostgreSQL-node test cluster running on one Docker host. It demonstrates database-level failover, but it does not protect against failure of the Windows machine or Docker host itself.
- If both PostgreSQL containers are on the same physical machine, they share that machine's hardware and host-level failure risks.
- A single HAProxy container can itself become a point of failure. Production deployments commonly provide redundant proxy instances and a stable virtual IP or load-balancer endpoint.
- etcd needs a resilient quorum configuration for production. Confirm the actual number of etcd members in the Compose setup.
- The test simulates a stopped PostgreSQL container. It does not test every possible failure, such as network partition, disk failure or complete host loss.
- PostgreSQL replication may be asynchronous or synchronous depending on Patroni/PostgreSQL configuration. A successful test does not, by itself, prove zero data loss for every possible failure.
- Applications should implement connection retry logic. HAProxy can route new connections after failover, but it cannot preserve an interrupted database session.
- Keep PostgreSQL data in persistent Docker volumes. Do not remove volumes during routine restarts.

## 14. Quick recap

| Component | Simple explanation |
|---|---|
| Docker Compose | Creates and runs the containers and network |
| PostgreSQL primary | Accepts writes and generates WAL |
| PostgreSQL replica | Receives and replays WAL from the primary |
| Patroni | Monitors and manages PostgreSQL roles and failover |
| etcd | Holds shared coordination state and the leader lock |
| HAProxy | Routes application connections to the current primary |

**Overall flow:** Docker runs the services. PostgreSQL replicates the data. Patroni manages the database nodes. etcd coordinates leadership. HAProxy routes application connections.
