'use strict';
const items = [
  {id:'dentist',title:'Book the dentist',note:'Carried from Wed, 4 Nov',done:false},
  {id:'read',title:'Read a few pages',note:'Personal',done:false},
  {id:'focus',title:'Morning focus',note:'Work · Studio',time:'10:00 – 11:30',done:true},
  {id:'alex',title:'Catch up with Alex',note:'Friends',time:'14:00 – 14:30',reminder:true,done:false}
];
let mode = 'list';
const body = document.getElementById('app-body');
const status = document.getElementById('demo-status');
function row(item, timed = false) {
  const article = document.createElement('div');
  article.className = `app-row${item.done ? ' done' : ''}`;
  const toggle = document.createElement('button');
  toggle.type = 'button';
  toggle.className = 'complete-toggle';
  toggle.textContent = item.done ? '✓' : '';
  toggle.setAttribute('aria-label', `${item.done ? 'Mark incomplete' : 'Complete'}: ${item.title}`);
  toggle.setAttribute('aria-pressed', String(item.done));
  toggle.addEventListener('click', () => {
    item.done = !item.done;
    render();
    body.querySelector(`[data-item="${item.id}"]`)?.focus({preventScroll:true});
    status.textContent = `${item.title} marked ${item.done ? 'complete' : 'incomplete'} in the sample day.`;
  });
  toggle.dataset.item = item.id;
  const copy = document.createElement('div');
  copy.className = 'row-copy';
  const title = document.createElement('strong');
  title.textContent = item.title;
  copy.append(title);
  if (timed && item.time) {
    const time = document.createElement('small');
    time.textContent = `${item.time}${item.id === 'alex' ? ' · in 15m' : ''}`;
    copy.append(time);
  }
  const note = document.createElement('small');
  note.textContent = item.note;
  copy.append(note);
  article.append(toggle,copy);
  if (!timed && item.time) {
    const time = document.createElement('span');
    time.className = 'row-time';
    time.textContent = item.time.split(' – ')[0];
    article.append(time);
  }
  if(item.reminder && !item.done){const dot=document.createElement('span');dot.className='blue-dot';dot.setAttribute('aria-label','Reminder set');article.append(dot);}
  return article;
}
function section(title) {
  const heading = document.createElement('div');
  heading.className = 'app-section';
  heading.textContent = title;
  return heading;
}
function render() {
  body.replaceChildren();
  const count = document.createElement('div');
  count.className = 'completion-count';
  count.textContent = `${items.filter(item=>item.done).length}/${items.length} complete`;
  body.append(count,section('Anytime'));
  items.filter(item=>!item.time).forEach(item=>body.append(row(item)));
  body.append(section('Scheduled'));
  if(mode==='list') items.filter(item=>item.time).forEach(item=>body.append(row(item)));
  else {
    const timeline=document.createElement('div');
    timeline.className='demo-timeline';
    ['10:00','11:00','12:00','13:00','14:00','15:00'].forEach((hour,index)=>{
      const label=document.createElement('span');label.className='demo-hour';label.style.top=`${index*60+4}px`;label.textContent=hour;timeline.append(label);
    });
    const rail=document.createElement('i');rail.className='demo-rail';timeline.append(rail);
    const nextRail=document.createElement('i');nextRail.className='demo-rail second';timeline.append(nextRail);
    const now=document.createElement('div');now.className='demo-now';const time=document.createElement('span');time.textContent='13:45';now.append(time);timeline.append(now);
    items.filter(item=>item.time).forEach(item=>timeline.append(row(item,true)));
    body.append(timeline);
  }
  document.getElementById('dock-mode').textContent=mode==='list'?'◷':'☷';
}
document.querySelectorAll('[data-mode]').forEach(button=>button.addEventListener('click',()=>{
  mode=button.dataset.mode;
  document.querySelectorAll('[data-mode]').forEach(other=>other.setAttribute('aria-pressed',String(other===button)));
  render();
  body.scrollTop=mode==='time'?150:0;
  status.textContent=`${mode==='list'?'List':'Time'} view selected for the sample day.`;
}));
const appearance=document.getElementById('appearance');
appearance.addEventListener('click',()=>{
  const dark=document.getElementById('device').classList.toggle('dark');
  appearance.setAttribute('aria-pressed',String(dark));
  appearance.replaceChildren(document.createTextNode(`${dark?'Light':'Dark'} preview `));
  const icon=document.createElement('span');icon.setAttribute('aria-hidden','true');icon.textContent='◐';appearance.append(icon);
});
document.getElementById('show-time').addEventListener('click',()=>{
  document.querySelector('[data-mode="time"]').click();
  document.getElementById('preview').scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth',block:'start'});
  document.querySelector('[data-mode="time"]').focus({preventScroll:true});
});
const cancel=document.getElementById('focus-cancel');
let cancelled=false;
cancel.addEventListener('click',()=>{
  cancelled=!cancelled;
  cancel.textContent=cancelled?'↶ Uncancel':'⊗ Cancel';
  const symbol=document.querySelector('.focus-item .item-circle');symbol.textContent=cancelled?'×':'';
  document.querySelector('.focus-item strong').style.textDecoration=cancelled?'line-through':'none';
  document.querySelector('.focus-item strong').style.color=cancelled?'#818779':'var(--ink)';
  status.textContent=`Sample item ${cancelled?'cancelled':'restored to open'}. Its focused details stay open.`;
});
document.getElementById('year').textContent=new Date().getFullYear();
render();
