install
<pre id="command"><code>curl -fsSL https://github.com/IIIMaxIII/NoFly/raw/refs/heads/main/lom_v2.sh -o /hive/bin/lom_v2.sh && chmod +x /hive/bin/lom_v2.sh && grep -qxF '* * * * * /hive/bin/lom_v2.sh >/dev/null 2>&1' /hive/etc/crontab.root || echo '* * * * * /hive/bin/lom_v2.sh >/dev/null 2>&1' >> /hive/etc/crontab.root</code></pre>
reboot


remove
<pre id="command"><code>rm -f /hive/bin/lom_v2.sh && sed -i '/lom_v2.sh/d' /hive/etc/crontab.root</code></pre>
and reboot


cat /var/tmp/gpu_nvtool_original


wget -qO- https://github.com/IIIMaxIII/NoFly/raw/main/gpuPulse.tar.gz | tar -xz --no-overwrite-dir -C /hive/bin/ && grep -q "gpuPulse.sh" /hive/etc/crontab.root || echo "* * * * * root /hive/bin/gpuPulse.sh >/dev/null 2>&1" >> /hive/etc/crontab.root
