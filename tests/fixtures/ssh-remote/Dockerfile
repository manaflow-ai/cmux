FROM alpine:3.20

RUN apk add --no-cache openssh python3 iproute2 net-tools ncurses bash

RUN adduser -D -s /bin/bash dev \
    && awk -F: 'BEGIN { OFS=":" } $1 == "root" { $7 = "/bin/bash" } { print }' /etc/passwd > /etc/passwd.tmp \
    && mv /etc/passwd.tmp /etc/passwd \
    && mkdir -p /home/dev/.ssh /run/sshd /srv/www \
    && chown -R dev:dev /home/dev/.ssh \
    && chmod 700 /home/dev/.ssh \
    && echo "cmux-ssh-forward-ok" > /srv/www/index.html

RUN ssh-keygen -A

COPY sshd_config /etc/ssh/sshd_config
COPY run.sh /usr/local/bin/run.sh
COPY ws_echo.py /usr/local/bin/ws_echo.py
RUN chmod +x /usr/local/bin/run.sh

EXPOSE 22

CMD ["/usr/local/bin/run.sh"]
