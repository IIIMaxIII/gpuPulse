install


```curl -fsSL https://github.com/IIIMaxIII/NoFly/raw/refs/heads/main/lom3.sh -o /hive/bin/lom3.sh && chmod +x /hive/bin/lom3.sh && grep -qxF '* * * * * /hive/bin/lom3.sh >/dev/null 2>&1' /hive/etc/crontab.root || echo '* * * * * /hive/bin/lom3.sh >/dev/null 2>&1' >> /hive/etc/crontab.root```
