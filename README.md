install
<pre id="command"><code>curl -fsSL https://github.com/IIIMaxIII/NoFly/raw/refs/heads/main/lom_v2.sh -o /hive/bin/lom_v2.sh && chmod +x /hive/bin/lom_v2.sh && grep -qxF '* * * * * /hive/bin/lom_v2.sh >/dev/null 2>&1' /hive/etc/crontab.root || echo '* * * * * /hive/bin/lom_v2.sh >/dev/null 2>&1' >> /hive/etc/crontab.root</code></pre>
reboot
