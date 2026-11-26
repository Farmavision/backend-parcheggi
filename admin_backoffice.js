module.exports = function registerAdminBackoffice(app, { useSupabase, supabase, getSystemSettings, processExpiredReleaseVerifications, logAuditEvent, logCreditLedger, betaFeedbacks }) {
  const getAdminPin = () => String(process.env.ADMIN_PIN || '2026').trim();

  function checkPin(req) {
    const provided = String(
      req.headers['x-admin-pin'] ||
      (req.query && req.query.pin) ||
      (req.body && req.body.pin) ||
      ''
    ).trim();
    return provided.length > 0 && provided === getAdminPin();
  }

  function requireAdminPin(req, res, next) {
    if (!checkPin(req)) {
      return res.status(401).json({ error: 'PIN amministratore non valido' });
    }
    next();
  }

  app.post('/api/admin/verify-pin', (req, res) => {
    if (!checkPin(req)) {
      return res.status(401).json({ ok: false, error: 'PIN errato' });
    }
    return res.json({ ok: true });
  });

  app.get('/api/admin/spots-summary', requireAdminPin, async (req, res) => {
    try {
      if (!useSupabase) {
        return res.json({
          timestamp: new Date().toISOString(),
          counts: { total: 0, occupied: 0, leavingSoon: 0, free: 0 },
          spots: [],
        });
      }
      if (typeof processExpiredReleaseVerifications === 'function') {
        try { await processExpiredReleaseVerifications(); } catch (_) {}
      }
      const settings = typeof getSystemSettings === 'function' ? await getSystemSettings() : {};
      const ttlMin = Number(settings.free_spot_ttl_minutes || 15);
      const cutoffIso = new Date(Date.now() - ttlMin * 60 * 1000).toISOString();
      try {
        await supabase.from('parking_spots').delete().eq('status', 'FREE').lt('updated_at', cutoffIso);
      } catch (_) {}

      const { data: spots, error } = await supabase
        .from('parking_spots')
        .select('*')
        .order('updated_at', { ascending: false });
      if (error) throw error;

      const list = Array.isArray(spots) ? spots : [];
      let occupied = 0, leavingSoon = 0, free = 0;
      for (const s of list) {
        const st = String(s.status || '').toUpperCase();
        if (st === 'OCCUPIED') occupied++;
        else if (st === 'LEAVING_SOON') leavingSoon++;
        else if (st === 'FREE') free++;
      }

      return res.json({
        timestamp: new Date().toISOString(),
        counts: { total: list.length, occupied, leavingSoon, free },
        spots: list,
      });
    } catch (err) {
      return res.status(500).json({ error: 'Errore lettura stalli live', details: err.message });
    }
  });

  app.post('/api/admin/spots/force-release', requireAdminPin, async (req, res) => {
    try {
      if (!useSupabase) return res.json({ success: true });
      const { spotId, userId, removeSpot = false } = req.body || {};
      if (!spotId && !userId) {
        return res.status(400).json({ error: 'spotId o userId richiesto' });
      }
      const nowIso = new Date().toISOString();
      let targetUserId = userId || null;
      let targetSpotId = spotId || null;

      if (removeSpot) {
        let q = supabase.from('parking_spots').delete();
        q = spotId ? q.eq('id', spotId) : q.eq('user_id', userId);
        await q;
      } else {
        let q = supabase.from('parking_spots').update({
          status: 'FREE',
          available_in_minutes: 0,
          confirmed_at: null,
          verification_deadline: null,
          updated_at: nowIso,
        });
        q = spotId ? q.eq('id', spotId) : q.eq('user_id', userId);
        const { data } = await q.select();
        if (Array.isArray(data) && data.length > 0) {
          targetUserId = targetUserId || data[0].user_id;
          targetSpotId = targetSpotId || data[0].id;
        }
      }

      if (targetUserId && typeof logAuditEvent === 'function') {
        await logAuditEvent(targetUserId, 'ADMIN_FORCE_RELEASE', {
          triggerSource: 'ADMIN_BACKOFFICE',
          spotId: targetSpotId,
          meta: { removeSpot: Boolean(removeSpot) },
        });
      }
      return res.json({ success: true, spotId: targetSpotId, userId: targetUserId });
    } catch (err) {
      return res.status(500).json({ error: 'Errore sblocco forzato stallo', details: err.message });
    }
  });

  app.get('/api/admin/users', requireAdminPin, async (req, res) => {
    try {
      if (!useSupabase) return res.json({ users: [] });
      const qRaw = String(req.query.q || '').trim().toLowerCase();

      const { data: usersData, error: uErr } = await supabase
        .from('users')
        .select('*')
        .neq('external_user_id', '__SYSTEM_ADMIN_ZONES__')
        .order('updated_at', { ascending: false });
      if (uErr) throw uErr;

      const { data: activeSpots } = await supabase
        .from('parking_spots')
        .select('*')
        .in('status', ['OCCUPIED', 'LEAVING_SOON']);

      const spotByUser = {};
      for (const sp of (activeSpots || [])) {
        if (sp.user_id && !spotByUser[sp.user_id]) spotByUser[sp.user_id] = sp;
      }

      let result = (usersData || []).map((u) => ({
        id: u.id,
        external_user_id: u.external_user_id,
        email: u.email || '',
        phone_number: u.phone_number || '',
        credits_balance: Number(u.credits_balance ?? 0),
        is_beta_tester: Boolean(u.is_beta_tester),
        is_suspended: Boolean(u.is_suspended),
        auto_share_enabled: Boolean(u.auto_share_enabled),
        car_brand: u.car_brand || '',
        car_model: u.car_model || '',
        car_color: u.car_color || '',
        car_plate_visible: u.car_plate_visible || '',
        search_radius_m: Number(u.search_radius_m || 500),
        updated_at: u.updated_at || u.created_at || null,
        active_spot: spotByUser[u.external_user_id] || null,
      }));

      if (qRaw) {
        result = result.filter((u) =>
          String(u.external_user_id || '').toLowerCase().includes(qRaw) ||
          String(u.email || '').toLowerCase().includes(qRaw) ||
          String(u.phone_number || '').toLowerCase().includes(qRaw) ||
          String(u.car_plate_visible || '').toLowerCase().includes(qRaw) ||
          String(u.car_brand || '').toLowerCase().includes(qRaw) ||
          String(u.car_model || '').toLowerCase().includes(qRaw)
        );
      }

      return res.json({ users: result });
    } catch (err) {
      return res.status(500).json({ error: 'Errore caricamento utenti', details: err.message });
    }
  });

  app.get('/api/admin/users/:userId/detail', requireAdminPin, async (req, res) => {
    try {
      const externalUserId = String(req.params.userId || '').trim();
      if (!externalUserId) return res.status(400).json({ error: 'userId mancante' });
      if (!useSupabase) {
        return res.json({ user: null, activeSpot: null, ledger: [], auditLogs: [], schemaReady: false });
      }

      const { data: user, error: uErr } = await supabase
        .from('users')
        .select('*')
        .eq('external_user_id', externalUserId)
        .maybeSingle();
      if (uErr) throw uErr;
      if (!user) return res.status(404).json({ error: 'Utente non trovato' });

      const { data: activeSpot } = await supabase
        .from('parking_spots')
        .select('*')
        .eq('user_id', externalUserId)
        .in('status', ['OCCUPIED', 'LEAVING_SOON'])
        .order('updated_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      let schemaReady = true;
      let ledger = [];
      try {
        const { data: lData, error: lErr } = await supabase
          .from('user_credit_ledger')
          .select('*')
          .eq('user_id', externalUserId)
          .order('created_at', { ascending: false })
          .limit(100);
        if (lErr) schemaReady = false;
        else ledger = lData || [];
      } catch (_) {
        schemaReady = false;
      }

      try {
        const { data: txData } = await supabase
          .from('credit_transactions')
          .select('*')
          .eq('user_id', user.id)
          .order('created_at', { ascending: false })
          .limit(50);
        if (Array.isArray(txData) && txData.length > 0) {
          const existingTs = new Set(ledger.map((x) => String(x.created_at || '').slice(0, 19)));
          for (const tx of txData) {
            const key = String(tx.created_at || '').slice(0, 19);
            if (!existingTs.has(key)) {
              ledger.push({
                id: `tx_${tx.id}`,
                user_id: externalUserId,
                delta: Number(tx.amount || 0),
                balance_after: null,
                reason_code: tx.transaction_type || 'LEGACY_TX',
                note: 'Storico transazioni precedente',
                spot_id: tx.spot_id || null,
                actor: 'SYSTEM',
                created_at: tx.created_at,
              });
            }
          }
          ledger.sort((a, b) => String(b.created_at || '').localeCompare(String(a.created_at || '')));
        }
      } catch (_) {}

      let auditLogs = [];
      try {
        const { data: aData, error: aErr } = await supabase
          .from('user_audit_logs')
          .select('*')
          .eq('user_id', externalUserId)
          .order('created_at', { ascending: false })
          .limit(100);
        if (aErr) schemaReady = false;
        else auditLogs = aData || [];
      } catch (_) {
        schemaReady = false;
      }

      if (Array.isArray(betaFeedbacks)) {
        for (const fb of betaFeedbacks) {
          if (fb.userId === externalUserId) {
            auditLogs.push({
              id: `fb_${fb.id}`,
              user_id: externalUserId,
              event_type: 'BETA_FEEDBACK',
              trigger_source: fb.category || 'APP',
              meta: { message: fb.message, diagnostics: fb.diagnostics },
              created_at: fb.createdAt,
            });
          }
        }
        auditLogs.sort((a, b) => String(b.created_at || '').localeCompare(String(a.created_at || '')));
      }

      return res.json({
        user: { ...user, email: user.email || '', is_suspended: Boolean(user.is_suspended) },
        activeSpot: activeSpot || null,
        ledger,
        auditLogs,
        schemaReady,
      });
    } catch (err) {
      return res.status(500).json({ error: 'Errore dettaglio utente', details: err.message });
    }
  });

  app.post('/api/admin/users/:userId/update', requireAdminPin, async (req, res) => {
    try {
      const externalUserId = String(req.params.userId || '').trim();
      if (!externalUserId) return res.status(400).json({ error: 'userId mancante' });
      if (!useSupabase) return res.json({ success: true });

      const { email, phoneNumber, isBetaTester, isSuspended } = req.body || {};
      const nowIso = new Date().toISOString();

      const fullPayload = { updated_at: nowIso };
      if (email !== undefined) fullPayload.email = String(email).trim() || null;
      if (phoneNumber !== undefined) fullPayload.phone_number = String(phoneNumber).trim() || null;
      if (isBetaTester !== undefined) fullPayload.is_beta_tester = Boolean(isBetaTester);
      if (isSuspended !== undefined) fullPayload.is_suspended = Boolean(isSuspended);

      let schemaWarning = null;
      let { data, error } = await supabase
        .from('users')
        .update(fullPayload)
        .eq('external_user_id', externalUserId)
        .select()
        .maybeSingle();

      if (error) {
        const fallbackPayload = { updated_at: nowIso };
        if (phoneNumber !== undefined) fallbackPayload.phone_number = String(phoneNumber).trim() || null;
        if (isBetaTester !== undefined) fallbackPayload.is_beta_tester = Boolean(isBetaTester);
        const retry = await supabase
          .from('users')
          .update(fallbackPayload)
          .eq('external_user_id', externalUserId)
          .select()
          .maybeSingle();
        if (retry.error) throw retry.error;
        data = retry.data;
        schemaWarning = 'Esegui lo script SQL su Supabase per abilitare le colonne email e is_suspended.';
      }

      if (typeof logAuditEvent === 'function') {
        await logAuditEvent(externalUserId, 'ADMIN_USER_UPDATE', {
          triggerSource: 'ADMIN_BACKOFFICE',
          meta: { email: fullPayload.email, is_beta_tester: fullPayload.is_beta_tester, is_suspended: fullPayload.is_suspended },
        });
      }

      return res.json({ success: true, user: data, schemaWarning });
    } catch (err) {
      return res.status(500).json({ error: 'Errore aggiornamento utente', details: err.message });
    }
  });

  app.post('/api/admin/users/:userId/adjust-credits', requireAdminPin, async (req, res) => {
    try {
      const externalUserId = String(req.params.userId || '').trim();
      const delta = Number(req.body?.delta);
      const reasonCode = String(req.body?.reasonCode || 'ADMIN_ADJUSTMENT').trim().toUpperCase();
      const note = String(req.body?.note || '').trim();
      const spotId = req.body?.spotId ? String(req.body.spotId).trim() : null;

      if (!externalUserId) return res.status(400).json({ error: 'userId mancante' });
      if (!Number.isFinite(delta) || delta === 0) {
        return res.status(400).json({ error: 'Inserisci un importo crediti diverso da zero' });
      }
      if (note.length < 3) {
        return res.status(400).json({ error: 'Inserisci una nota/motivazione (min. 3 caratteri)' });
      }
      if (!useSupabase) return res.json({ success: true, newBalance: 50 + delta });

      let { data: user } = await supabase
        .from('users')
        .select('*')
        .eq('external_user_id', externalUserId)
        .maybeSingle();
      if (!user) return res.status(404).json({ error: 'Utente non trovato' });

      const newBalance = Number(user.credits_balance || 0) + Math.trunc(delta);
      const { error: upErr } = await supabase
        .from('users')
        .update({ credits_balance: newBalance, updated_at: new Date().toISOString() })
        .eq('id', user.id);
      if (upErr) throw upErr;

      try {
        await supabase.from('credit_transactions').insert({
          user_id: user.id,
          amount: Math.trunc(delta),
          transaction_type: reasonCode,
          spot_id: spotId,
        });
      } catch (_) {}

      if (typeof logCreditLedger === 'function') {
        await logCreditLedger(externalUserId, Math.trunc(delta), newBalance, reasonCode, {
          note,
          spotId,
          actor: 'ADMIN',
        });
      }
      if (typeof logAuditEvent === 'function') {
        await logAuditEvent(externalUserId, 'ADMIN_CREDIT_ADJUST', {
          triggerSource: 'ADMIN_BACKOFFICE',
          spotId,
          meta: { delta: Math.trunc(delta), newBalance, reasonCode, note },
        });
      }

      return res.json({ success: true, newBalance, delta: Math.trunc(delta) });
    } catch (err) {
      return res.status(500).json({ error: 'Errore rettifica crediti', details: err.message });
    }
  });
};
