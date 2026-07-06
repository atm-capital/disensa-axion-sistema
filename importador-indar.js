/* Importador Indar → Axion Tools
   Se ejecuta DENTRO de indar.mx (con tu sesión iniciada) mediante el botón de marcador.
   Lee la cotización elegida, junta partidas, precios y descripciones, y abre
   el sistema Axion Tools con todo listo para confirmar la importación. */
(async function(){
  const APP = 'https://atm-capital.github.io/disensa-axion-sistema/';
  const b64 = s => btoa(unescape(encodeURIComponent(s))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
  if(!/indar\.mx$/.test(location.hostname)){ alert('Este botón se usa dentro de indar.mx (con tu sesión iniciada).'); return; }
  const aviso = msg => { let el = document.getElementById('ax-aviso');
    if(!el){ el = document.createElement('div'); el.id='ax-aviso';
      el.style.cssText='position:fixed;top:14px;left:50%;transform:translateX(-50%);z-index:99999;background:#26292b;color:#fff;padding:12px 22px;border-radius:10px;font:14px sans-serif;border-left:5px solid #E8790F;box-shadow:0 8px 30px rgba(0,0,0,.4)';
      document.body.appendChild(el); }
    el.textContent = '🔧 Axion: ' + msg; };
  const tok = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '';
  async function post(url, body){
    const r = await fetch(url, {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded','X-CSRF-TOKEN':tok,'X-Requested-With':'XMLHttpRequest'}, body});
    return r.json();
  }
  try{
    aviso('leyendo cotizaciones...');
    let doc = document;
    if(!/pedidosAnteriores/i.test(location.pathname)){
      const t = await fetch('/pedidosAnteriores').then(r=>r.text());
      doc = new DOMParser().parseFromString(t,'text/html');
    }
    const cots = [...doc.querySelectorAll('.item-box[onclick*="showCotizacionModal"]')].map(e=>{
      const n = (e.getAttribute('onclick').match(/\((\d+)\)/)||[])[1];
      return {n, txt: e.textContent.replace(/\s+/g,' ').trim().slice(0,70)};
    }).filter(c=>c.n);
    if(!cots.length){ alert('No encontré cotizaciones. Entra a "Pedidos" → "Pedidos Anteriores" y vuelve a dar clic en el botón.'); return; }
    const folio = prompt('¿Qué cotización importo a Axion Tools?\n\n' + cots.map(c=>'• '+c.txt).join('\n') + '\n\nEscribe el número:', cots[0].n);
    if(!folio) { document.getElementById('ax-aviso')?.remove(); return; }
    aviso('buscando partes del pedido ' + folio + '...');
    function leerSOs(d){
      return [...d.querySelectorAll('.item-box2[onclick*="openDetail"]')].map(e=>{
        const id = (e.getAttribute('onclick').match(/'(\d+)'/)||[])[1];
        const m = e.textContent.match(new RegExp(folio + '-(\\d+)\\/(\\d+)'));
        return (m && id) ? {id, parte:+m[1], serie:+m[2]} : null;
      }).filter(Boolean);
    }
    let sos = [];
    if(typeof showCotizacionModal === 'function' && /pedidosAnteriores/i.test(location.pathname)){
      showCotizacionModal(+folio);
      await new Promise(r=>setTimeout(r, 900));
      sos = leerSOs(document);
    } else { sos = leerSOs(doc); }
    if(!sos.length){ alert('No encontré las partes de la cotización ' + folio + '. Abre "Pedidos Anteriores", da clic en la cotización para ver sus partes, y vuelve a usar el botón.'); return; }
    // Evitar series duplicadas (ej. partes x/4 que repiten a las x/6): usar la serie más completa
    const serieMax = Math.max(...sos.map(s=>s.serie));
    const usados = [...new Map(sos.filter(s=>s.serie===serieMax).map(s=>[s.id,s])).values()];
    aviso('leyendo partidas de ' + usados.length + ' parte(s)...');
    const items = {};
    for(const so of usados){
      const dets = await post('/pedidosAnteriores/getDetalleFacturado', 'id=' + so.id);
      if(Array.isArray(dets)) for(const it of dets){
        const k = it.itemid;
        items[k] = items[k] || {c:k, q:0, e:0, f:0};
        items[k].q += +it.cantPedido || 0;
        items[k].e += +it.cantEmpacada || 0;
        items[k].f += +it.cantFacturada || 0;
      }
    }
    const cods = Object.keys(items);
    if(!cods.length){ alert('Las partes no regresaron partidas. Intenta de nuevo en unos minutos.'); return; }
    let i = 0;
    for(const cod of cods){
      i++; aviso('leyendo precios ' + i + '/' + cods.length + '...');
      try{
        const t = await fetch('/portal/detallesProducto/' + encodeURIComponent(cod.replace(/ /g,'_'))).then(r=>r.text());
        const d = new DOMParser().parseFromString(t,'text/html');
        const lista = (t.match(/Precio Lista:[\s\S]{0,120}?\$\s*([\d,]+\.?\d*)/)||[])[1];
        const sug = (t.match(/Prec\. sugerido de venta:[\s\S]{0,120}?\$\s*([\d,]+\.?\d*)/)||[])[1];
        items[cod].l = lista ? parseFloat(lista.replace(/,/g,'')) : null;
        items[cod].s = sug ? parseFloat(sug.replace(/,/g,'')) : null;
        items[cod].d = d.querySelector('.purchasedescription')?.textContent.trim() || cod;
      }catch(e){ items[cod].d = cod; }
    }
    const payload = {v:1, tipo:'pedido', folio:String(folio), fecha:new Date().toISOString().slice(0,10),
      serie:serieMax, sos:usados.map(s=>s.id), items:Object.values(items)};
    aviso('abriendo Axion Tools...');
    window.open(APP + '#import=' + b64(JSON.stringify(payload)), '_blank');
    setTimeout(()=>document.getElementById('ax-aviso')?.remove(), 3000);
  }catch(e){
    alert('Axion: algo falló (' + e.message + '). Intenta de nuevo o avísale a Claude.');
  }
})();
