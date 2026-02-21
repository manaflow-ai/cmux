FROM alpine:3.20

RUN apk add --no-cache openssh python3 iproute2 net-tools ncurses

RUN adduser -D -s /bin/sh dev \
    && mkdir -p /home/dev/.ssh /run/sshd /srv/www \
    && chown -R dev:dev /home/dev/.ssh \
    && chmod 700 /home/dev/.ssh \
    && echo "cmux-ssh-forward-ok" > /srv/www/index.html

RUN ssh-keygen -A

COPY sshd_config /etc/ssh/sshd_config
COPY run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh

EXPOSE 22

CMD ["/usr/local/bin/run.sh"]
