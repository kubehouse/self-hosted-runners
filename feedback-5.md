```sh
❯ Running containerized task for target=smoke                                                                                               
failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix    
/var/run/docker.sock: connect: no such file or directory     
```

his is a race condition within each runner pod between the runner and dind containers. Both start simultaneously — but dockerd inside the
   dind container takes a few seconds to start and create /var/run/docker.sock. When a single pod starts there's usually enough slack; when
  two pods start at the same time the node is busier, dockerd initialises slower, and the runner starts executing workflow steps before the
  socket exists.

  The fix is a postStart lifecycle hook on the runner container that blocks until the socket is present: (arc.tf)


Root cause: dind and runner are sidecar containers — Kubernetes starts them at the same time. dockerd inside dind needs a few seconds to
  initialise before it creates /var/run/docker.sock. With a single job there's usually enough slack, but when two pods start simultaneously
  the node is under more CPU pressure, dockerd initialises slower, and the runner container begins executing workflow steps (including any
  docker call) before the socket file exists.

  Fix: A postStart lifecycle hook on the runner container:
  until [ -S /var/run/docker.sock ]; do sleep 1; done
  Kubernetes blocks the container from receiving its first job step until postStart completes, so by the time /home/runner/run.sh runs
  Docker jobs, dockerd is guaranteed to be listening on the socket. The -S flag checks for a socket file specifically, not just any file.

✻ Churned for 56s

❯ Does this create a queue? For example one pipeline finishes first, then the 2nd starts and so on?                                         
                                                                                                    
⏺ No. Each runner pod is completely independent — they run in parallel, not in sequence.                                                    
                                                                                                                                          
  What the postStart hook does is much narrower: it makes each pod wait (up to a few seconds) for its own dind container's socket to be     
  ready before that pod's runner starts executing steps. It has no effect on other pods.
                                                                                                                                            
  The concurrency model looks like this:                                                                                                    
   
  Pod A:  [dind starts] --[socket ready]--> [runner executes job A] --> done                                                                
  Pod B:  [dind starts] --[socket ready]--> [runner executes job B] --> done                                                                
                               ↑
                      both pods run simultaneously;                                                                                         
                      each waits only for its own socket                                                                                  
                                                                                                                                            
  Each pod has its own emptyDir volume for the socket (dind-sock), its own dockerd process, and its own isolated Docker layer cache. They   
  share nothing with each other.
                                                                                                                                            
  If you want to actually limit concurrency — e.g. cap at N simultaneous jobs — that's controlled by maxRunners in the Helm values, which is
   currently set to 5. Lowering it to 1 would make jobs queue, but that would defeat the purpose of the scale-out architecture.