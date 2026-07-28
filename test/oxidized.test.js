const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const script = fs.readFileSync(
  path.join(__dirname, '..', 'lib/oxidized/web/public/scripts/oxidized.js'),
  'utf8'
);

function loadStateOptions(href, storedState) {
  const storage = new Map();
  if(storedState) {
    storage.set(
      'oxidized.datatable.v1.nodesTable',
      JSON.stringify(storedState)
    );
  }

  const window = {
    location: { href },
    history: {
      state: null,
      replaceState(state, title, nextHref) {
        this.state = state;
        window.location.href = nextHref;
      }
    },
    sessionStorage: {
      getItem(key) {
        return storage.has(key) ? storage.get(key) : null;
      },
      setItem(key, value) {
        storage.set(key, value);
      }
    }
  };

  const context = {
    URL,
    console,
    document: { title: 'oxidized' },
    window,
    $: function(argument) {
      // Do not run the document-ready handlers in this unit test.
      return argument;
    }
  };

  vm.runInNewContext(script, context);

  return {
    options: context.dataTableStateOptions('nodesTable'),
    storage,
    window
  };
}

function settings(visibility = [true, false, true]) {
  return {
    aoColumns: visibility.map((visible) => ({
      bVisible: visible,
      sName: ''
    })),
    aaSorting: [[0, 'asc']],
    _iDisplayLength: 20
  };
}

test('saves the complete shareable state while preserving other URL parameters', () => {
  const environment = loadStateOptions(
    'http://example.test/node/version?node_full=group%2Fswitch'
  );
  const state = {
    time: Date.now(),
    start: 100,
    length: 50,
    order: [[2, 'desc'], [0, 'asc']],
    search: { search: 'edge routers' },
    columns: [
      { visible: true },
      { visible: false },
      { visible: true }
    ]
  };

  environment.options.stateSaveCallback(settings(), state);

  const url = new URL(environment.window.location.href);
  assert.equal(url.searchParams.get('node_full'), 'group/switch');
  assert.equal(url.searchParams.get('dt_state'), 'nodesTable');
  assert.equal(url.searchParams.get('dt_length'), '50');
  assert.equal(url.searchParams.get('dt_start'), '100');
  assert.equal(url.searchParams.get('dt_order'), '2:desc,0:asc');
  assert.equal(url.searchParams.get('dt_columns'), '101');
  assert.equal(url.searchParams.get('dt_search'), 'edge routers');
  assert.deepEqual(
    JSON.parse(environment.storage.get('oxidized.datatable.v1.nodesTable')),
    state
  );
});

test('loads URL state before a different state from the session', () => {
  const sessionState = {
    time: Date.now(),
    start: 0,
    length: 20,
    order: [[0, 'asc']],
    search: { search: 'session search' },
    columns: [{ visible: true }, { visible: true }, { visible: true }]
  };
  const environment = loadStateOptions(
    'http://example.test/nodes?dt_state=nodesTable' +
      '&dt_length=250&dt_start=500&dt_order=2:desc,0:asc' +
      '&dt_columns=101&dt_search=shared',
    sessionState
  );

  const state = environment.options.stateLoadCallback(settings());

  assert.equal(state.length, 250);
  assert.equal(state.start, 500);
  assert.deepEqual(JSON.parse(JSON.stringify(state.order)), [
    [2, 'desc'],
    [0, 'asc']
  ]);
  assert.equal(state.search.search, 'shared');
  assert.deepEqual(
    Array.from(state.columns, (column) => column.visible),
    [true, false, true]
  );
});

test('uses session state when the URL has no table state', () => {
  const sessionState = {
    time: Date.now(),
    start: 40,
    length: 20,
    order: [[1, 'desc']],
    search: { search: 'sticky' },
    columns: [{ visible: true }, { visible: false }, { visible: true }]
  };
  const environment = loadStateOptions(
    'http://example.test/nodes?unrelated=value',
    sessionState
  );

  const state = environment.options.stateLoadCallback(settings());

  assert.deepEqual(JSON.parse(JSON.stringify(state)), sessionState);
});
