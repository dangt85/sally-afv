const pptxgen = require("pptxgenjs");

// 16:9, sized so a title can be large on a screen share.
const W = 13.333;
const H = 7.5;

const C = {
  cream: "F3EEE4",
  creamDeep: "E9E1D2",
  card: "F7F3EB",
  dark: "24362C",
  body: "3E5144",
  muted: "5C6B60",
  accent: "A86647",
  onDark: "F3EEE4",
  onDarkSoft: "E4D5C8",
  line: "D9CDB8",
};

const SERIF = "Georgia";
const SANS = "Arial";

const sessions = [
  {
    file: "session-01-a-person-answers.pptx",
    n: 1,
    title: [
      { text: "A person answers", options: { breakLine: true } },
      { text: "the phone." },
    ],
    promise: "Stand up Amazon Connect and Salesforce Voice, then take one call.",
    cardsTitle: "Only two of these exist today.",
    cards: [
      {
        kicker: "01",
        title: "Amazon Connect",
        body: "Owns the phone number, the greeting, and the contact flow.",
        live: true,
      },
      {
        kicker: "02",
        title: "Salesforce Voice",
        body: "Where the rep picks up. Softphone, voice-call record, and the queue.",
        live: true,
      },
      {
        kicker: "Later",
        title: "The agent",
        body: "Same number. It does not exist yet.",
        live: false,
      },
    ],
    stepsTitle: "Then I share my screen.",
    steps: [
      ["Create the contact center", "Salesforce provisions Amazon Connect."],
      ["Claim one number", "Attach it to the sample inbound flow."],
      ["One queue, one rep", "English only. The rep is Available."],
      ["Call the number", "Answer it in Salesforce."],
    ],
    leaveOut: "Name the Spanish queue. Don't put anyone in it.",
    doneKicker: "Done when",
    doneTitle: "You hear it ring.",
    doneBody: "I answer the call in Salesforce. Then we stop.",
    next: "Next session — the same number rings the agent first.",
    notes: [
      "Cairn is a small outdoor retailer. Every support call is a person, including the easy ones. Today we only build the phone system those calls arrive on. The agent is the next session.",
      "Connect is the phone side: the number, the greeting, the contact flow. Salesforce is where a rep works: the softphone, the voice-call record, the queue. If someone asks about the agent, the answer is the same number, next time. Don't open Agent Builder.",
      "Clean org. Contact-center creation can sit on a spinner — talk through what Salesforce is creating, and cut the wait if it runs long. The first call usually fails on presence, the routing profile, or the number not being on the flow. Fix that live. Don't edit the flow to add the agent, even if you finish early.",
      "Place the call. Answer it. Hang up. One sentence on the way out: next time this number rings the agent, and this queue is where a person still picks up.",
    ],
  },
  {
    file: "session-02-the-agent-answers.pptx",
    n: 2,
    title: [
      { text: "The agent answers.", options: { breakLine: true } },
      { text: "Then a person does." },
    ],
    promise: "The same number rings the agent first. Asking for a person comes back to last session's queue.",
    cardsTitle: "One new piece, in front of the phone you already have.",
    cards: [
      {
        kicker: "New",
        title: "The agent",
        body: "It can greet, and it can hand the call to a person. Nothing else.",
        live: true,
      },
      {
        kicker: "Edit",
        title: "The contact flow",
        body: "The public number rings the agent before it rings the queue.",
        live: true,
      },
      {
        kicker: "Same",
        title: "The queue",
        body: "Last session's rep is still the person who picks up.",
        live: false,
      },
    ],
    stepsTitle: "On screen.",
    steps: [
      ["Scaffold the agent", "A greeting, and a way to reach a person."],
      ["Claim its number", "This is not the number customers dial."],
      ["Edit the contact flow", "Transfer there first. Continue when that leg ends."],
      ["Ask for a person", "Last session's rep should ring."],
    ],
    leaveOut: "No orders and no articles. Greeting and transfer only.",
    doneKicker: "Done when",
    doneTitle: "A person still picks up.",
    doneBody: "You ask the agent for a human. The rep from session 1 answers.",
    next: "Next session — where's my order?",
    notes: [
      "Open by calling the number from last session so people remember a human answers. Today we put an agent in front of that, and we keep the human path.",
      "Two different numbers. Customers still dial the Connect number. The agent has its own number, and the contact flow transfers to it. When that leg ends, the flow continues into the queue. That continuation is not the same thing as the agent choosing to escalate.",
      "Keep the agent dumb on purpose. If the transfer works with time left, add the case fallback: no rep available, a case gets created. If the transfer doesn't work yet, spend the time on the transfer.",
      "Demo line: call, talk to the agent, say you want a person, land on the rep. Stop there.",
    ],
  },
  {
    file: "session-03-wheres-my-order.pptx",
    n: 3,
    title: [{ text: "Where's my order?" }],
    promise: "Load the customers and orders. A known caller and an unknown caller each get the right one.",
    cardsTitle: "The agent can finally answer something.",
    cards: [
      {
        kicker: "Known",
        title: "Their number matches",
        body: "One account. The agent already knows who is calling.",
        live: true,
      },
      {
        kicker: "Unknown",
        title: "Prove the order",
        body: "Order number plus the date it was placed. Or a person.",
        live: true,
      },
      {
        kicker: "Not today",
        title: "Data Cloud",
        body: "This version is a Flow against Salesforce.",
        live: false,
      },
    ],
    stepsTitle: "On screen.",
    steps: [
      ["Load customers and orders", "Products too, only because orders need them."],
      ["Wire up the Flow", "Order number, total, status, delivery date."],
      ["Call from a known number", "It should not ask who they are."],
      ["Call from anywhere else", "Both facts, or hand the call to a person."],
    ],
    leaveOut: "Don't open Data Cloud. Don't load the FAQ articles.",
    doneKicker: "Done when",
    doneTitle: "Both calls are right.",
    doneBody: "A known caller hears their order. An unknown caller has to prove it.",
    next: "Next session — what's your return policy?",
    notes: [
      "The phone and the transfer already work. Today the agent is allowed to know about orders, and only orders.",
      "Two calls, two rules. If the incoming number matches exactly one person, use it. If it matches nobody or more than one, an order number alone is not enough — they also need the date the order was placed. Wrong, or missing, and the call goes to a person. Don't read the order number and total back to someone you couldn't identify.",
      "The lookup is the Flow. Say out loud that this is the simple version and it will be replaced. Resist opening Data Cloud.",
      "Place both calls. Check the answer against the order record before you hang up.",
    ],
  },
  {
    file: "session-04-return-policy.pptx",
    n: 4,
    title: [
      { text: "What's your", options: { breakLine: true } },
      { text: "return policy?" },
    ],
    promise: "Answer from the FAQ articles. Then show why the Apex retriever is faster.",
    cardsTitle: "Same articles. Two ways of reading them.",
    cards: [
      {
        kicker: "First",
        title: "Prompt template",
        body: "The built-in retriever. This is the baseline.",
        live: true,
      },
      {
        kicker: "Then",
        title: "Apex vector search",
        body: "Same index, without the template in the way.",
        live: true,
      },
      {
        kicker: "The point",
        title: "Compare them",
        body: "One question, asked twice. Listen for the wait.",
        live: false,
      },
    ],
    stepsTitle: "On screen.",
    steps: [
      ["Publish the articles", "Drafts don't get retrieved."],
      ["Ask about returns", "Answer has to come from the article."],
      ["Swap in the Apex action", "Take the template retriever out."],
      ["Ask the same question", "Same answer. Less waiting."],
    ],
    leaveOut: "Don't index the product manuals.",
    doneKicker: "Done when",
    doneTitle: "The second one is faster.",
    doneBody: "Same return-policy answer. The wait is the lesson, not a new feature.",
    next: "Next session — read the manual, then upgrade the order lookup.",
    notes: [
      "Orders work. Today is company questions: returns, shipping, warranty. Not product how-tos.",
      "Build the slow one first and let the audience feel it. Then replace the retriever. Don't change the question between the two calls or the comparison is muddy.",
      "Articles loaded by the data script land as drafts. If retrieval is empty, they aren't published yet. Say that when it happens.",
      "One question is enough. Returns is the one people remember. Mention you'll do product manuals next, from the PDFs, not from these articles.",
    ],
  },
  {
    file: "session-05-the-manual.pptx",
    n: 5,
    title: [
      { text: "Read the manual.", options: { breakLine: true } },
      { text: "Then upgrade the order." },
    ],
    promise: "A product question comes from the manual. Order lookup moves to the data graph.",
    cardsTitle: "Two upgrades. The phone doesn't change.",
    cards: [
      {
        kicker: "Manual",
        title: "Product question",
        body: "How to clean the filter. Why the stove won't ignite. From the PDF.",
        live: true,
      },
      {
        kicker: "Graph",
        title: "Order lookup",
        body: "A known caller stops repeating what Salesforce already has.",
        live: true,
      },
      {
        kicker: "If time",
        title: "No Connect",
        body: "Agentforce Contact Center is this agent without Amazon Connect.",
        live: false,
      },
    ],
    stepsTitle: "On screen.",
    steps: [
      ["Ask the manual", "Something the FAQ articles cannot answer."],
      ["Check the index", "Hybrid. The wizard defaults to vector."],
      ["Map the orders by hand", "Skip the Salesforce data kit on purpose."],
      ["Call as a known customer", "The order comes back without a quiz."],
    ],
    leaveOut: "Don't rebuild Connect. This hour is grounding.",
    doneKicker: "Done when",
    doneTitle: "Both answers are grounded.",
    doneBody: "The manual answer is real. The known caller isn't asked to start over.",
    next: "That's the series. Contact Center is the coda, not a sixth build.",
    notes: [
      "Last session. Two changes, one phone number. Start with the product question because it's new. The order upgrade is the same question as session 3, answered from a different place.",
      "Hybrid, not vector, so exact phrases like \"won't ignite\" aren't outranked. The search-index wizard selects vector by default, and you cannot switch it in place. Worth showing the checkbox before you build it.",
      "Map Account, Order, Order Item, and Product yourself. Say why you're not clicking the data kit: the mapping is the lesson. Ingestion is not instant. If a new order is missing, wait, don't rebuild.",
      "If the two demos landed, spend two minutes on Contact Center: same agent, Salesforce is the phone system, no Connect. Don't start that build.",
    ],
  },
];

function kicker(slide, left, right, color = C.accent) {
  slide.addText(left, {
    x: 0.65,
    y: 0.38,
    w: 6.2,
    h: 0.32,
    fontFace: SANS,
    fontSize: 12,
    color,
    charSpacing: 1.6,
    margin: 0,
    valign: "middle",
  });
  slide.addText(right, {
    x: 7.3,
    y: 0.38,
    w: 5.38,
    h: 0.32,
    fontFace: SANS,
    fontSize: 12,
    color: C.muted,
    align: "right",
    charSpacing: 1.4,
    margin: 0,
    valign: "middle",
  });
}

function addTitleSlide(pres, session) {
  const slide = pres.addSlide();
  slide.background = { color: C.cream };
  kicker(slide, "CODE WITH SALLY", `SESSION ${session.n}  OF  5`);
  slide.addText(session.title, {
    x: 0.65,
    y: 1.85,
    w: 12.0,
    h: 2.7,
    fontFace: SERIF,
    fontSize: 60,
    color: C.dark,
    margin: 0,
    valign: "top",
  });
  slide.addText(session.promise, {
    x: 0.65,
    y: 5.15,
    w: 10.6,
    h: 1.15,
    fontFace: SANS,
    fontSize: 20,
    color: C.body,
    margin: 0,
  });
  slide.addNotes(session.notes[0]);
}

function addCardsSlide(pres, session) {
  const slide = pres.addSlide();
  slide.background = { color: C.cream };
  kicker(slide, "CAIRN OUTDOOR CO.", `SESSION ${session.n}`);
  slide.addText(session.cardsTitle, {
    x: 0.65,
    y: 0.9,
    w: 12.0,
    h: 0.7,
    fontFace: SERIF,
    fontSize: 32,
    color: C.dark,
    margin: 0,
  });

  const cardW = 3.8;
  const gap = 0.28;
  const y = 2.0;
  const h = 4.7;
  session.cards.forEach((card, i) => {
    const x = 0.65 + i * (cardW + gap);
    slide.addShape(pres.shapes.RECTANGLE, {
      x,
      y,
      w: cardW,
      h,
      fill: { color: card.live ? C.dark : C.card },
      line: card.live ? { type: "none" } : { color: C.line, width: 1.25 },
    });
    slide.addText(card.kicker.toUpperCase(), {
      x: x + 0.32,
      y: y + 0.36,
      w: cardW - 0.64,
      h: 0.32,
      fontFace: SANS,
      fontSize: 13,
      color: card.live ? C.onDarkSoft : C.accent,
      charSpacing: 1.4,
      margin: 0,
    });
    slide.addText(card.title, {
      x: x + 0.32,
      y: y + 1.15,
      w: cardW - 0.64,
      h: 1.35,
      fontFace: SERIF,
      fontSize: 26,
      color: card.live ? C.onDark : C.dark,
      margin: 0,
    });
    slide.addText(card.body, {
      x: x + 0.32,
      y: y + 2.7,
      w: cardW - 0.64,
      h: 1.55,
      fontFace: SANS,
      fontSize: 16,
      color: card.live ? C.onDarkSoft : C.body,
      margin: 0,
    });
  });
  slide.addNotes(session.notes[1]);
}

function addStepsSlide(pres, session) {
  const slide = pres.addSlide();
  slide.background = { color: C.cream };
  kicker(slide, "ON SCREEN", `SESSION ${session.n}`);
  slide.addText(session.stepsTitle, {
    x: 0.65,
    y: 0.86,
    w: 12.0,
    h: 0.62,
    fontFace: SERIF,
    fontSize: 32,
    color: C.dark,
    margin: 0,
  });

  session.steps.forEach((step, i) => {
    const y = 1.78 + i * 1.12;
    slide.addText(String(i + 1).padStart(2, "0"), {
      x: 0.65,
      y,
      w: 0.85,
      h: 0.48,
      fontFace: SERIF,
      fontSize: 22,
      color: C.accent,
      margin: 0,
      valign: "middle",
    });
    slide.addText(step[0], {
      x: 1.7,
      y,
      w: 10.8,
      h: 0.4,
      fontFace: SERIF,
      fontSize: 22,
      color: C.dark,
      margin: 0,
    });
    slide.addText(step[1], {
      x: 1.7,
      y: y + 0.4,
      w: 10.8,
      h: 0.34,
      fontFace: SANS,
      fontSize: 15,
      color: C.muted,
      margin: 0,
    });
  });

  slide.addText(session.leaveOut, {
    x: 0.65,
    y: 6.85,
    w: 12.0,
    h: 0.32,
    fontFace: SANS,
    fontSize: 14,
    color: C.accent,
    margin: 0,
  });
  slide.addNotes(session.notes[2]);
}

function addCloseSlide(pres, session) {
  const slide = pres.addSlide();
  slide.background = { color: C.dark };
  slide.addText(session.doneKicker.toUpperCase(), {
    x: 0.7,
    y: 1.45,
    w: 11.8,
    h: 0.34,
    fontFace: SANS,
    fontSize: 13,
    color: C.onDarkSoft,
    charSpacing: 1.8,
    margin: 0,
  });
  slide.addText(session.doneTitle, {
    x: 0.7,
    y: 2.0,
    w: 11.8,
    h: 1.35,
    fontFace: SERIF,
    fontSize: 48,
    color: C.onDark,
    margin: 0,
  });
  slide.addText(session.doneBody, {
    x: 0.7,
    y: 3.55,
    w: 10.5,
    h: 1.05,
    fontFace: SANS,
    fontSize: 20,
    color: C.onDarkSoft,
    margin: 0,
  });
  slide.addText(session.next, {
    x: 0.7,
    y: 5.7,
    w: 11.5,
    h: 0.45,
    fontFace: SANS,
    fontSize: 16,
    color: C.onDark,
    margin: 0,
  });
  slide.addNotes(session.notes[3]);
}

function build(session) {
  const pres = new pptxgen();
  pres.defineLayout({ name: "WIDE_16x9", width: W, height: H });
  pres.layout = "WIDE_16x9";
  pres.title = `Session ${session.n} — Cairn Outdoor Co.`;
  pres.author = "Daniel Gonzalez";
  pres.subject = "Code with Sally — Agentforce Voice";
  addTitleSlide(pres, session);
  addCardsSlide(pres, session);
  addStepsSlide(pres, session);
  addCloseSlide(pres, session);
  return pres.writeFile({
    fileName: `${__dirname}/${session.file}`,
  });
}

Promise.all(sessions.map(build)).then(() => {
  sessions.forEach((session) => console.log(session.file));
});
