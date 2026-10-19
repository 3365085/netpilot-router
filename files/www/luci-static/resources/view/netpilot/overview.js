'use strict';
'require view';

return view.extend({
    render: function() {
        return E('div', {}, [
            E('h2', {}, 'NetPilot 网络助手'),
            E('p', {}, '为当前设备选择直连、DNS 去广告、代理或去广告与代理。控制台使用现有路由器账号登录。'),
            E('a', {
                'class': 'cbi-button cbi-button-apply',
                'href': '/netpilot.html',
                'target': '_blank',
                'rel': 'noopener'
            }, '打开网络控制台')
        ]);
    },
    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
