# 本地 GoAnywhere 行为模拟器：跳板 + 目标机双 sshd，同一容器，两个端口。
# 用途：不依赖真实比赛服务器即可端到端验证 jump-ssh-persist skill。
#   - 2222 = "跳板"（模拟 GoAnywhere：先认证再转发）
#   - 2223 = "目标机"（模拟 root@199.103.53.195）
# 凭据：用户 root，密码 mockpass（token 置为 root 即模拟有效 token；
#       token 置为其它用户即模拟 token 失效 → Permission denied）。
FROM alpine:3.20
RUN apk add --no-cache openssh bash && \
    ssh-keygen -A && \
    echo 'root:mockpass' | chpasswd && \
    mkdir -p /run/sshd && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config
COPY sshd_jump.conf /etc/ssh/sshd_jump.conf
COPY sshd_target.conf /etc/ssh/sshd_target.conf
EXPOSE 2222 2223
CMD ["sh", "-c", "/usr/sbin/sshd -f /etc/ssh/sshd_jump.conf && /usr/sbin/sshd -f /etc/ssh/sshd_target.conf && tail -f /dev/null"]
