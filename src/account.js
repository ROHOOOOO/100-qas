(function () {
  var questions = [
    '你童年最喜欢的玩具叫什么？',
    '你第一次独自旅行的目的地是哪里？',
    '你记忆最深的一位老师叫什么？',
    '你最喜欢的一本书叫什么？',
    '你为自己设定的秘密口令是什么？'
  ];
  window.createAccountModule = function (api) {
    var recovery = null, epoch = 0;
    var e = api.escape;
    function notice() {
      return api.local() ? '<p class="preview-notice">本地试玩：账号和房间只保存在这个浏览器。线上账号请在正式网站登录。</p>' : '';
    }
    function accountField(value) {
      return '<label for="account-username">账号</label><input id="account-username" name="username" autocomplete="username" maxlength="20" required placeholder="2-20位，支持中文/英文/数字/下划线" value="' + e(value || '') + '"><p class="field-hint">账号仅用于登录，不会作为游戏中的显示名称。</p>';
    }
    function nameField(value) {
      return '<label for="account-display-name">用户名</label><input id="account-display-name" name="displayName" autocomplete="nickname" maxlength="20" required placeholder="1–20 个字，朋友们看到的名字" value="' + e(value || '') + '"><p class="field-hint">允许重名，可在账号设置中修改。</p>';
    }
    function answerField(id, placeholder) {
      return '<label for="' + id + '">密保答案</label><div class="account-answer-control"><input id="' + id + '" name="answer" type="text" inputmode="text" required maxlength="100" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="' + placeholder + '">' +
        '<button class="ghost-button" type="button" data-answer-toggle="' + id + '" aria-controls="' + id + '" aria-pressed="false">隐藏答案</button></div>';
    }
    function passwordFields(isNew) {
      return '<label for="account-password">' + (isNew ? '设置密码' : '密码') + '</label><input id="account-password" name="password" type="password" autocomplete="' + (isNew ? 'new-password' : 'current-password') + '" required minlength="4" maxlength="72" placeholder="至少4位，请勿使用重要账号密码">' +
        (isNew ? '<label for="account-password-confirm">确认密码</label><input id="account-password-confirm" name="confirmPassword" type="password" autocomplete="new-password" required minlength="4" maxlength="72" placeholder="再次输入密码">' : '');
    }
    function form(kind, fields, label) {
      return '<form class="stack-form account-form" data-account="' + kind + '"><fieldset class="account-fields">' + fields +
        '<p class="account-error" role="alert" hidden></p><button class="primary-button" type="submit">' + label + '</button></fieldset></form>';
    }
    function shell(title, lead, content) {
      document.title = title + ' | Friends Games';
      api.shell('<main class="account-layout"><section class="panel account-panel account-access"><p class="eyebrow">Your place to play</p><h1>' + title + '</h1><p class="muted">' + lead + '</p>' + notice() + content + '</section></main>', 'account');
    }
    function login() {
      shell('登录', '所有功能共用账号，同一浏览器自动记住登录。',
        '<nav class="account-tabs" aria-label="账号入口"><a href="#account" aria-current="page">登录</a><a href="#account/register">注册新账号</a></nav>' +
        form('login', accountField('') + passwordFields(false), '登录') + '<a class="account-recovery-link" href="#account/recover">忘记密码？</a>');
    }
    function register() {
      var options = questions.map(function (q, index) { return '<option value="' + (index + 1) + '">' + e(q) + '</option>'; }).join('');
      shell('注册新账号', '所有功能共用账号，用一个用户名和朋友一起玩。',
        '<nav class="account-tabs" aria-label="账号入口"><a href="#account">登录</a><a href="#account/register" aria-current="page">注册新账号</a></nav>' +
        form('register', accountField('') + nameField('') + passwordFields(true) +
          '<div class="account-section-heading"><h2>设置密保</h2><p class="field-hint">选择 1 个问题，忘记密码时用答案验证身份。</p></div>' +
          '<label for="account-security-question">密保问题</label><select id="account-security-question" name="question" required>' + options + '</select>' +
          answerField('account-security-answer', '支持中文、英文和数字') + '<p class="field-hint">支持中文、英文和数字。英文不区分大小写，忽略首尾空格。请记住你的答案。</p>', '注册并登录'));
    }
    function settings() {
      var user = api.account();
      shell('账号设置', '所有功能共用账号，游戏中统一展示你的用户名。',
        '<a class="account-back" href="#account">← 我的记录</a>' +
        '<p class="account-login-id">登录账号：<strong>' + e(user.username) + '</strong></p>' +
        form('profile', nameField(user.displayName), '保存用户名') +
        '<p class="field-hint">更新后，房间里的当前名称和新记录使用新用户名。已有历史保留当时的名称。</p>');
    }
    function recoveryPage() {
      recovery = recovery || { stage: 1, username: '' };
      var stage = recovery.stage;
      var steps = '<ol class="account-steps" aria-label="找回密码步骤">' + ['输入账号', '验证密保', '设置密码'].map(function (label, i) {
        return '<li' + (stage === i+1 ? ' aria-current="step"' : '') + '><span>' + (i+1) + '</span>' + label + '</li>';
      }).join('') + '</ol>';
      var body;
      if (stage === 1) body = form('recovery-question', accountField(recovery.username), '下一步');
      else if (stage === 2) body = '<p class="account-question">' + e(questions[recovery.questionId-1]) + '</p>' +
        form('recovery-verify', answerField('recovery-answer', '输入注册时设置的答案') + '<p class="field-hint">支持中文、英文和数字。英文不区分大小写，忽略首尾空格。15 分钟内连续答错 5 次后，需等待 15 分钟。</p>', '验证答案') +
        '<button class="ghost-button" data-account="recovery-restart" type="button">重新输入账号</button>';
      else body = '<p class="account-verified">密保验证通过，请在 10 分钟内设置新密码。</p>' +
        form('recovery-reset', passwordFields(true), '重设密码') + '<p class="field-hint">设置成功后，所有设备需要使用新密码重新登录。</p>';
      shell('找回密码', '通过账号和密保问题，重新设置密码。', steps + body + '<a class="account-recovery-link" href="#account">返回登录</a>');
    }
    function errorMessage(error) {
      var text = error && error.message || '';
      if (/temporarily blocked/.test(text)) return '密保验证失败次数过多，请 15 分钟后再试。你仍可使用原密码登录。';
      if (/Recovery verification/.test(text)) return '账号或密保答案不正确，请检查后重试。';
      if (/Reset token/.test(text)) return '验证已过期或已使用，请重新验证密保。';
      if (/display name/.test(text)) return '用户名需要 1–20 个字。';
      if (/security question/.test(text)) return '请选择一个密保问题。';
      if (/security answer/.test(text)) return '请填写 1–100 个字的密保答案。';
      if (/Username already exists|duplicate key/i.test(text)) return '这个登录账号已被使用，请换一个账号。用户名可以重复。';
      if (/Invalid username or password/.test(text)) return '账号或密码不正确。';
      if (/Invalid username/.test(text)) return '账号需要 2–20 位，只支持中文、英文、数字和下划线。';
      if (/too short/.test(text)) return '密码至少需要 4 位。';
      if (/too long/.test(text)) return '密码过长，请缩短后再试。';
      if (/Passwords do not match/.test(text)) return '两次输入的密码不一致。';
      if (/Login required/.test(text)) return '登录已失效，请重新登录。';
      return '暂时未能完成，请检查网络后重试。';
    }
    function checkPasswords(values) {
      if (values.get('password') !== values.get('confirmPassword')) throw new Error('Passwords do not match.');
    }
    document.addEventListener('click', function (event) {
      var toggle = event.target.closest('[data-answer-toggle]');
      if (toggle) {
        var input = document.getElementById(toggle.dataset.answerToggle);
        var hide = input.type === 'text';
        input.type = hide ? 'password' : 'text';
        toggle.textContent = hide ? '显示答案' : '隐藏答案';
        toggle.setAttribute('aria-pressed', String(hide));
      }
      if (event.target.closest('[data-account="recovery-restart"]')) { epoch++; recovery = null; recoveryPage(); }
    });
    document.addEventListener('submit', async function (event) {
      var formNode = event.target, kind = formNode.dataset.account;
      if (!kind) return;
      event.preventDefault();
      var fields = formNode.querySelector('fieldset'), errorNode = formNode.querySelector('.account-error');
      if (fields.disabled) return;
      var generation = epoch, values = new FormData(formNode), result;
      fields.disabled = true; errorNode.hidden = true;
      try {
        if (kind === 'login' || kind === 'register') {
          var args = { p_username: values.get('username'), p_password: values.get('password') };
          if (kind === 'register') {
            checkPasswords(values);
            Object.assign(args, { p_display_name: values.get('displayName'), p_security_question: Number(values.get('question')), p_security_answer: values.get('answer') });
          }
          result = await api.rpc(kind === 'register' ? 'account_register' : 'account_login', args);
          if (generation !== epoch) return;
          api.save(result); api.toast(kind === 'register' ? '注册成功，已登录。' : '已登录。'); api.afterLogin();
        } else if (kind === 'profile') {
          result = await api.rpc('account_update_profile', { p_account_token: api.token(), p_display_name: values.get('displayName') });
          if (generation !== epoch) return;
          api.save(result); settings(); api.toast('用户名已更新。');
        } else if (kind === 'recovery-question') {
          result = await api.rpc('account_recovery_question', { p_username: values.get('username') });
          if (generation !== epoch) return;
          recovery = { stage: 2, username: String(values.get('username')).trim(), questionId: result.questionId }; recoveryPage();
        } else if (kind === 'recovery-verify') {
          result = await api.rpc('account_verify_recovery', { p_username: recovery.username, p_answer: values.get('answer') });
          if (generation !== epoch) return;
          if (!result.ok) throw new Error(result.error);
          recovery = { stage: 3, token: result.resetToken }; recoveryPage();
        } else if (kind === 'recovery-reset') {
          checkPasswords(values);
          result = await api.rpc('account_reset_password', { p_reset_token: recovery.token, p_password: values.get('password') });
          if (generation !== epoch) return;
          if (!result.ok) {
            recovery = null; recoveryPage(); api.toast(errorMessage(new Error(result.error))); return;
          }
          api.clear(); recovery = null; api.route('account'); api.toast('密码已重设，请使用新密码登录。');
        }
      } catch (error) {
        if (generation === epoch && errorNode.isConnected) { errorNode.textContent = errorMessage(error); errorNode.hidden = false; }
      } finally { if (fields.isConnected) fields.disabled = false; }
    });
    return {
      render: function (view) {
        epoch++;
        if (view !== 'recover') recovery = null;
        if (view === 'recover') { recoveryPage(); return true; }
        if (!api.account()) { if (view === 'register') register(); else login(); return true; }
        if (view === 'settings') { settings(); return true; }
        return false;
      },
      leave: function () { epoch++; recovery = null; }
    };
  };
})();
